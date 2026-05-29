# Stage 8 — 給 inline 區塊傳參數:受控注入(host 傳值、block 宣告名字)
#
# Stage 7 的 block 不會執行,所以區塊內引用外層變數一律被拒。這一階段補上
# 「怎麼把外部值【受控地】送進去」——用 block 自己的參數當注入點:
#
#     config = loader.load_block(name, port: 8080) do |name, port:|
#       set :app,  name
#       set :port, port
#     end
#
# block 依然【不執行】。我們從 AST 讀出它【宣告的參數名】(BlockNode.parameters),
# 把 host 傳進來的引數綁到那些名字上,放進作用域的「參數槽」(與設定值分開,
# 不會混進輸出)。於是:
#   - 對【已宣告且已綁定】的參數,block 內的 LocalVariableRead 解析到注入值;
#   - 對【沒宣告】的外層閉包變數,引用仍被拒(並告訴你怎麼改成參數)。
#
# 這就是一條白名單:只有 host 明確傳入、且 block 明確宣告的名字才進得來,
# 零閉包洩漏。安全模型不變,只是多了一個「受控的入口」。

require "prism"

module PrismConfig
  class RejectedError < StandardError; end

  NOT_FOUND = Object.new.freeze

  # ── 作用域鏈:data 放設定值;params 放注入的參數(只在 root,子層往上找) ──
  class Scope
    attr_reader :data, :parent, :params

    def initialize(parent: nil, data: {}, params: {})
      @parent = parent
      @data   = data
      @params = params
    end

    def child(data: {})
      Scope.new(parent: self, data: data)
    end

    def []=(key, value)
      @data[key] = value
    end

    def resolve(key)
      scope = self
      while scope
        return scope.data[key] if scope.data.key?(key)
        scope = scope.parent
      end
      NOT_FOUND
    end

    # 參數和設定值分屬不同命名空間:ref(:k) 找設定值,裸名字找參數。
    def resolve_param(name)
      scope = self
      while scope
        return scope.params[name] if scope.params.key?(name)
        scope = scope.parent
      end
      NOT_FOUND
    end
  end

  # ── 註冊表(沿用 Stage 6) ──
  class Registry
    Entry = Struct.new(:handler, :wants_ctx, :block_mode, keyword_init: true)

    attr_reader :commands, :functions

    def initialize
      @commands  = {}
      @functions = {}
    end

    def command(name, block: false, &handler)
      @commands[name] = Entry.new(handler: handler, wants_ctx: true, block_mode: block)
    end

    def function(name, &handler)
      @functions[name] = Entry.new(handler: handler, wants_ctx: false, block_mode: false)
    end

    def scoped_function(name, &handler)
      @functions[name] = Entry.new(handler: handler, wants_ctx: true, block_mode: false)
    end
  end

  # ── Context 門面(沿用 Stage 6) ──
  class Context
    def initialize(loader, scope, node)
      @loader = loader
      @scope  = scope
      @node   = node
    end

    def set(key, value)
      @scope[key] = value
    end

    def [](key)
      value = @scope.resolve(key)
      value.equal?(NOT_FOUND) ? nil : value
    end

    def resolve(key)
      @scope.resolve(key)
    end

    def namespace(name)
      block = @node.block
      seed  = @scope.data[name].is_a?(Hash) ? @scope.data[name] : {}
      child = @scope.child(data: seed)
      @loader.evaluate_block(block, child)
      @scope[name] = child.data
      child.data
    end
  end

  class SafeLoader
    def self.define
      registry = Registry.new
      install_builtins(registry)
      yield registry if block_given?
      new(registry)
    end

    def self.install_builtins(reg)
      reg.command(:set) do |ctx, *args|
        raise ArgumentError, "set 需要 2 個參數(:key, value),收到 #{args.size} 個" unless args.size == 2
        key, value = args
        raise ArgumentError, "設定鍵必須是符號,例如 set :port, 3000" unless key.is_a?(Symbol)
        ctx.set(key, value)
      end

      reg.command(:group, block: :required) do |ctx, *args|
        raise ArgumentError, "group 需要 1 個名稱參數(:name),收到 #{args.size} 個" unless args.size == 1
        name = args.first
        raise ArgumentError, "group 名稱必須是符號,例如 group :database" unless name.is_a?(Symbol)
        ctx.namespace(name)
      end

      reg.scoped_function(:ref) do |ctx, *args|
        raise ArgumentError, "ref 需要 1 個符號參數,例如 ref(:host)" unless args.size == 1
        key = args.first
        raise ArgumentError, "ref 的參數必須是符號,例如 ref(:host)" unless key.is_a?(Symbol)
        value = ctx.resolve(key)
        if value.equal?(NOT_FOUND)
          raise ArgumentError, "ref(:#{key}) 找不到 —— 只能參照之前(同層或外層)已設定的 key"
        end
        value
      end
    end

    private_class_method :install_builtins

    def initialize(registry)
      @registry = registry
    end

    def load(source, filename: "(config)")
      prepare(filename)
      result = parse_or_raise(source)
      finish(result.value.statements)
    end

    # 從一個【不會被執行的】Ruby 區塊載入;區塊參數 = 受控注入點。
    def load_block(*args, **kwargs, &block)
      raise ArgumentError, "load_block 需要一個區塊" unless block

      file, line = block.source_location
      unless file && File.readable?(file)
        raise RejectedError, "拿不到區塊原始碼(可能跑在 eval / IRB 裡);inline DSL 需要可讀的原始檔"
      end

      prepare(file)
      result    = parse_or_raise(File.read(file))
      dsl_block = find_dsl_block(result.value, line)
      raise RejectedError, "在 #{file}:#{line} 找不到對應的 load_block 區塊" unless dsl_block

      bindings = bind_params(dsl_block, args, kwargs)
      finish(dsl_block.body, params: bindings)
    end

    def evaluate_block(block, scope)
      eval_statements(block.body, scope)
    end

    private

    def prepare(filename)
      @errors   = []
      @filename = filename
    end

    def parse_or_raise(source)
      result = Prism.parse(source)
      unless result.success?
        parse_errs = result.errors.map { |e| "  #{loc(e.location)} #{e.message}" }
        raise RejectedError, "無法解析(語法錯誤):\n#{parse_errs.join("\n")}"
      end
      result
    end

    def finish(statements, params: {})
      root = Scope.new(params: params)
      eval_statements(statements, root)
      unless @errors.empty?
        listing = @errors.map { |e| "  #{e}" }.join("\n")
        raise RejectedError, "設定有 #{@errors.size} 個問題:\n#{listing}"
      end
      root.data
    end

    def find_dsl_block(root, line)
      found = nil
      visit = lambda do |node|
        return if found || !node.is_a?(Prism::Node)
        if node.is_a?(Prism::CallNode) && node.name == :load_block &&
           node.block.is_a?(Prism::BlockNode) && node.block.location.start_line == line
          found = node.block
          return
        end
        node.compact_child_nodes.each { |c| visit.call(c) }
      end
      visit.call(root)
      found
    end

    # 把 host 傳入的 args/kwargs 綁到 block 宣告的參數名上。
    # 只支援:必需/可選位置參數、必需/可選關鍵字參數(維持受控,其餘明確拒絕)。
    # 綁定錯誤是「結構性」的,直接 raise(不進入逐句彙整)。
    def bind_params(block_node, args, kwargs)
      bp = block_node.parameters
      unless bp.is_a?(Prism::BlockParametersNode) && bp.parameters
        unless args.empty? && kwargs.empty?
          raise RejectedError, "load_block 傳了參數,但區塊沒有宣告參數(請寫成 do |…|)"
        end
        return {}
      end

      params = bp.parameters
      if params.rest || params.keyword_rest || !params.posts.empty? || params.block
        raise RejectedError, "區塊參數只支援必需/可選的位置參數與關鍵字參數;不支援 *rest、**kwrest、&block"
      end

      reqs = params.requireds
      opts = params.optionals
      if args.size < reqs.size
        names = reqs.map(&:name).join(", ")
        raise RejectedError, "區塊需要至少 #{reqs.size} 個位置參數(#{names}),只收到 #{args.size} 個"
      end
      if args.size > reqs.size + opts.size
        raise RejectedError, "區塊最多接受 #{reqs.size + opts.size} 個位置參數,收到 #{args.size} 個"
      end

      bindings = {}
      reqs.each_with_index { |p, i| bindings[p.name] = args[i] }
      opts.each_with_index do |p, i|
        idx = reqs.size + i
        bindings[p.name] = idx < args.size ? args[idx] : eval_default(p.value)
      end

      kwargs = kwargs.dup
      params.keywords.each do |p|
        if kwargs.key?(p.name)
          bindings[p.name] = kwargs.delete(p.name)
        elsif p.is_a?(Prism::OptionalKeywordParameterNode)
          bindings[p.name] = eval_default(p.value)
        else
          raise RejectedError, "區塊需要關鍵字參數 `#{p.name}:`,但 load_block 沒有傳"
        end
      end
      unless kwargs.empty?
        extra = kwargs.keys.map { |k| "#{k}:" }.join(", ")
        raise RejectedError, "區塊沒有宣告這些關鍵字參數:#{extra}"
      end

      bindings
    end

    # 參數預設值:只接受字面量/陣列/雜湊(綁定發生在還沒有設定值的階段)。
    def eval_default(node)
      case node
      when Prism::SymbolNode  then node.unescaped.to_sym
      when Prism::StringNode  then node.unescaped
      when Prism::IntegerNode then node.value
      when Prism::FloatNode   then node.value
      when Prism::TrueNode    then true
      when Prism::FalseNode   then false
      when Prism::NilNode     then nil
      when Prism::ArrayNode   then node.elements.map { |e| eval_default(e) }
      when Prism::HashNode, Prism::KeywordHashNode
        node.elements.each_with_object({}) do |a, h|
          raise RejectedError, "參數預設值的雜湊只接受 key => value 字面量對" unless a.is_a?(Prism::AssocNode)
          h[eval_default(a.key)] = eval_default(a.value)
        end
      else
        raise RejectedError, "參數預設值只接受字面量,不接受 #{describe(node)}"
      end
    end

    def eval_statements(statements, scope)
      return if statements.nil?
      statements.body.each do |node|
        catch(:abort_statement) { eval_statement(node, scope) }
      end
    end

    def eval_statement(node, scope)
      unless node.is_a?(Prism::CallNode) && node.receiver.nil?
        message =
          if describe(node).end_with?("Write")
            "不允許賦值(=);這個區塊不會被執行,只接受指令呼叫"
          else
            "只允許指令呼叫,不允許 #{describe(node)}"
          end
        record(node, message)
      end

      entry = @registry.commands[node.name]
      unless entry
        record(node, "未知指令 `#{node.name}`(目前可用:#{@registry.commands.keys.join(", ")})")
      end

      validate_block(node, entry)
      ctx     = Context.new(self, scope, node)
      pos, kw = split_args(node, scope)
      invoke(node, "指令", entry, [ctx, *pos], kw)
    end

    def eval_value(node, scope)
      case node
      when Prism::SymbolNode  then node.unescaped.to_sym
      when Prism::StringNode  then node.unescaped
      when Prism::IntegerNode then node.value
      when Prism::FloatNode   then node.value
      when Prism::TrueNode    then true
      when Prism::FalseNode   then false
      when Prism::NilNode     then nil
      when Prism::ArrayNode   then node.elements.map { |el| eval_value(el, scope) }
      when Prism::HashNode, Prism::KeywordHashNode then eval_hash(node, scope)
      when Prism::CallNode    then eval_function_call(node, scope)
      when Prism::LocalVariableReadNode
        # 已宣告的參數 → 取注入值;否則就是外層閉包變數 → 拒絕,並指路怎麼修。
        value = scope.resolve_param(node.name)
        if value.equal?(NOT_FOUND)
          record(node, "`#{node.name}` 不是這個區塊宣告的參數;區塊不會執行,拿不到外層區域變數。" \
                       "要用外部值,請宣告成區塊參數(do |#{node.name}|)並在 load_block 傳入")
        end
        value
      else
        record(node, "不支援的值 #{describe(node)};只接受字面量、陣列、雜湊、已註冊函數的呼叫,或區塊參數")
      end
    end

    def eval_function_call(node, scope)
      unless node.receiver.nil?
        record(node, "值裡的呼叫不可帶 receiver(例如 File.read(...)、env(...).split);只允許 f(...) 這種裸函數呼叫")
      end
      unless node.block.nil?
        record(node, "值裡的函數呼叫不可帶區塊(do…end 或 { })")
      end

      entry = @registry.functions[node.name]
      unless entry
        record(node, "未註冊的函數 `#{node.name}`;值裡只能用已註冊函數(目前:#{@registry.functions.keys.join(", ")})")
      end

      pos, kw = split_args(node, scope)
      args    = entry.wants_ctx ? [Context.new(self, scope, node), *pos] : pos
      invoke(node, "函數", entry, args, kw)
    end

    def split_args(node, scope)
      arg_nodes = (node.arguments&.arguments || []).dup
      kw_node   = arg_nodes.last.is_a?(Prism::KeywordHashNode) ? arg_nodes.pop : nil
      positional = arg_nodes.map { |n| eval_value(n, scope) }
      kwargs     = kw_node ? eval_kwargs(kw_node, scope) : {}
      [positional, kwargs]
    end

    def eval_kwargs(node, scope)
      node.elements.each_with_object({}) do |assoc, h|
        unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)
          record(assoc, "關鍵字參數的鍵必須是符號,例如 host:")
        end
        h[assoc.key.unescaped.to_sym] = eval_value(assoc.value, scope)
      end
    end

    def eval_hash(node, scope)
      node.elements.each_with_object({}) do |assoc, h|
        unless assoc.is_a?(Prism::AssocNode)
          record(assoc, "雜湊裡不支援 #{describe(assoc)}(例如 ** 展開);只接受 key => value 字面量對")
        end
        key = eval_value(assoc.key, scope)
        val = eval_value(assoc.value, scope)
        h[key] = val
      end
    end

    def invoke(node, kind, entry, args, kwargs)
      entry.handler.call(*args, **kwargs)
    rescue ArgumentError => e
      record(node, "#{kind} `#{node.name}` 的參數不正確:#{e.message}")
    rescue => e
      record(node, "#{kind} `#{node.name}` 執行失敗:#{e.message}")
    end

    def validate_block(node, entry)
      block = node.block
      if block && !block.is_a?(Prism::BlockNode)
        record(node, "不支援的區塊形式 #{describe(block)}")
      end

      case entry.block_mode
      when false
        record(node, "`#{node.name}` 不接受 do…end 區塊") if block
      when :required
        record(node, "`#{node.name}` 需要一個 do…end 區塊") unless block.is_a?(Prism::BlockNode)
      end

      record(block, "區塊不接受參數(do |x| 不允許)") if block.is_a?(Prism::BlockNode) && block.parameters
    end

    def describe(node)
      node.class.name.split("::").last.sub(/Node$/, "")
    end

    def loc(location)
      "#{@filename}:#{location.start_line}:#{location.start_column + 1}:"
    end

    def record(node, message)
      @errors << "#{loc(node.location)} #{message}"
      throw :abort_statement
    end
  end
end
