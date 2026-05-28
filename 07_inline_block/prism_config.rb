# Stage 7 — inline DSL 區塊:程式碼長得像 Ruby block,卻走 Prism 解析(不執行)
#
# 到 Stage 6 為止,DSL 來源都是「字串 / .conf 檔」。這一階段把來源換成
# 【正常 Ruby 檔裡的一個 block】:
#
#     config = loader.load_block do
#       set :host, "localhost"
#       set :port, 3000
#     end
#
# 關鍵:這個 block【從不被執行】—— 我們不 call、不 yield、不 instance_eval。
# 而是用 `Proc#source_location` 拿到 [檔案, 行],把那個檔讀進來、用 Prism 解析,
# 在 AST 裡找到對應的 BlockNode,再把它的 body 丟進【同一套】安全直譯器。
#
# 這把整個項目的論點濃縮成一個最直觀的對照:
#   它【看起來】是 method-based(你在 block 裡寫 set :host, …),
#   骨子裡卻是 parse-not-eval —— 所以區塊裡就算寫了 system(...)、File.read、
#   `$g = 1`、引用外層變數,統統不會發生,只會被解析、被檢視、被拒絕。
#
# 安全引擎本身和 Stage 6 完全相同(統一註冊表 + 兩道閘門);新增的只有
# 「從 block 取得 AST」這條入口,以及對「看似可執行其實不會」的節點給的提示。

require "prism"

module PrismConfig
  class RejectedError < StandardError; end

  NOT_FOUND = Object.new.freeze

  # ── 作用域鏈(沿用):向後參照 → 自上而下一遍即確定、無循環 ──
  class Scope
    attr_reader :data, :parent

    def initialize(parent: nil, data: {})
      @parent = parent
      @data   = data
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
  end

  # ── 註冊表:整套 DSL 的詞彙表,白名單的唯一來源(沿用 Stage 6) ──
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

  # ── Context:傳給 handler 的門面;handler 看不到任何 AST(沿用 Stage 6) ──
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

    # 入口一:從字串 / .conf 載入(沿用 Stage 6)。
    def load(source, filename: "(config)")
      prepare(filename)
      result = parse_or_raise(source)
      finish(result.value.statements)
    end

    # 入口二(本階段新增):從一個【不會被執行的】Ruby 區塊載入。
    #   靠 source_location 取得原始碼位置 → 讀檔 → Prism → 找到該 BlockNode。
    #   全程沒有 call / yield / instance_eval:block 只被「解析」,從不「執行」。
    def load_block(filename: nil, &block)
      raise ArgumentError, "load_block 需要一個區塊" unless block

      file, line = block.source_location
      unless file && File.readable?(file)
        raise RejectedError, "拿不到區塊原始碼(可能跑在 eval / IRB 裡);inline DSL 需要可讀的原始檔"
      end

      prepare(filename || file)
      result     = parse_or_raise(File.read(file))
      dsl_block  = find_dsl_block(result.value, line)
      unless dsl_block
        raise RejectedError, "在 #{file}:#{line} 找不到對應的 load_block 區塊"
      end
      finish(dsl_block.body)
    end

    # 供 Context 回呼:把區塊內容走訪到指定子空間(handler 不直接碰 AST)。
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

    def finish(statements)
      root = Scope.new
      eval_statements(statements, root)
      unless @errors.empty?
        listing = @errors.map { |e| "  #{e}" }.join("\n")
        raise RejectedError, "設定有 #{@errors.size} 個問題:\n#{listing}"
      end
      root.data
    end

    # 在整棵樹裡找「呼叫 load_block 且 do…end 起始行 == line」的那個區塊。
    # 用「方法名 + 區塊起始行」定位,足以對上 Proc#source_location。
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

    # 每條語句包一層 catch:壞語句被跳過,迴圈繼續 —— 編譯器式錯誤復原。
    def eval_statements(statements, scope)
      return if statements.nil?
      statements.body.each do |node|
        catch(:abort_statement) { eval_statement(node, scope) }
      end
    end

    # 安全閘門一:只允許無 receiver 的裸呼叫,名字必須在【指令註冊表】裡。
    def eval_statement(node, scope)
      unless node.is_a?(Prism::CallNode) && node.receiver.nil?
        # 賦值看起來像「執行期動作」,特別點明:這個區塊不會執行。
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

    # 安全閘門二(遞迴、scope-aware)。
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
        # inline DSL 最常見的誤用:以為能順手用外層變數。點明 parse-not-eval。
        record(node, "這裡引用了區域變數 `#{node.name}`,但這個區塊是被【解析】、不會執行," \
                     "所以拿不到它的執行期值;請改用字面量,或透過 host 函數 / ref(...) 帶入")
      else
        record(node, "不支援的值 #{describe(node)};只接受字面量、陣列、雜湊,或已註冊函數的呼叫")
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

    # 呼叫 host handler。這是【唯一】會執行的 Ruby —— 而且是 host 自己寫的。
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
