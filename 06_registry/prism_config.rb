# Stage 6 — 受控方法調用:host 暴露一套接口(統一註冊表)的 Prism/AST 安全 DSL
#
# 到 Stage 5 為止,`set`/`group`/`ref` 是寫死在直譯器裡的白名單。這一階段把
# 白名單「從寫死變成 host 註冊」—— 這正是 method-based → AST 的核心轉折。
#
# method-based DSL 的「方法」(set/route/resource…)定義在 context 物件上,靠
# instance_eval 呼叫;不安全的點有兩個:方法本身(透過 send/metaprogramming
# 可達物件全部方法)和參數(任意 Ruby,system(...) 照跑)。
#
# 安全版把兩者都收緊成「host 宣告的接口」,守住一條不變量:
#
#   唯一會「執行」的 Ruby,是 host 自己寫的 command / function 區塊(可信)。
#   不可信的 .conf 只能做兩件事:(1) 指名一個【已註冊】的操作,
#   (2) 餵給它【安全的值】(字面量/陣列/雜湊/已註冊函數的回傳值)。
#   system、File.read、eval、send、反引號…… 不在註冊表 ⇒ 在名字閘門就被拒,
#   參數依然 parse-not-eval。
#
# 於是直譯器從「動詞寫死的 config 載入器」升級成「詞彙由 host 宣告的安全 DSL
# 引擎」。set/group/ref 也改寫成【內建註冊項】,讓白名單只有一個來源。

require "prism"

module PrismConfig
  class RejectedError < StandardError; end

  NOT_FOUND = Object.new.freeze

  # ── 作用域鏈(沿用 Stage 4/5):向後參照 → 自上而下走一遍即確定、無循環 ──
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

  # ── 註冊表:整套 DSL 的「詞彙表」,白名單的唯一來源 ──────────────────
  #   command  = 語句層指令(有副作用 / 建構結構),handler 第一參數拿到 ctx。
  #   function = 值層函數(回傳一個值),預設純取值、不拿 ctx。
  #   scoped_function = 內建用:需要讀作用域的函數(如 ref)。
  class Registry
    Entry = Struct.new(:handler, :wants_ctx, :block_mode, keyword_init: true)

    attr_reader :commands, :functions

    def initialize
      @commands  = {}
      @functions = {}
    end

    # block: false(預設,不接受區塊)/ :required(必須帶 do…end)/ true(可選)
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

  # ── Context:傳給 handler 的門面 ──────────────────────────────────────
  #   handler 只看得到「已求出的值」和這幾個安全操作,看不到任何 AST。
  class Context
    def initialize(loader, scope, node)
      @loader = loader
      @scope  = scope
      @node   = node
    end

    # 寫入當前作用域
    def set(key, value)
      @scope[key] = value
    end

    # 沿鏈讀取;找不到回 nil(host handler 友善用法)
    def [](key)
      value = @scope.resolve(key)
      value.equal?(NOT_FOUND) ? nil : value
    end

    # 沿鏈讀取;找不到回 NOT_FOUND 哨符(內建 ref 用,需要區分「沒設過」)
    def resolve(key)
      @scope.resolve(key)
    end

    # 把本次呼叫的 do…end 區塊,當作一個命名子空間求值並存回 name。
    #   reopen 語義:子空間以 name 既有的雜湊作種子,讓區塊內可參照早先的 key。
    #   區塊內容是 AST,由引擎走訪;handler 永遠碰不到 AST。
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
    # host 在這裡宣告自己的接口;set/group/ref 先以內建註冊放好。
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
      @errors   = []
      @filename = filename

      result = Prism.parse(source)
      # 語法錯誤:Prism 本來就會一次給出全部,直接回報。
      unless result.success?
        parse_errs = result.errors.map { |e| "  #{loc(e.location)} #{e.message}" }
        raise RejectedError, "無法解析設定檔(語法錯誤):\n#{parse_errs.join("\n")}"
      end

      root = Scope.new
      eval_statements(result.value.statements, root)

      # 語意錯誤:走完整棵樹後,一次回報所有收集到的問題(沿用 Stage 5)。
      unless @errors.empty?
        listing = @errors.map { |e| "  #{e}" }.join("\n")
        raise RejectedError, "設定檔有 #{@errors.size} 個問題:\n#{listing}"
      end
      root.data
    end

    # 供 Context 回呼:把區塊內容走訪到指定子空間(handler 不直接碰 AST)。
    def evaluate_block(block, scope)
      eval_statements(block.body, scope)
    end

    private

    # 每條語句包一層 catch:壞語句被跳過,迴圈繼續下一條 —— 編譯器式錯誤復原。
    def eval_statements(statements, scope)
      return if statements.nil?
      statements.body.each do |node|
        catch(:abort_statement) { eval_statement(node, scope) }
      end
    end

    # 安全閘門一:只允許無 receiver 的裸呼叫,名字必須在【指令註冊表】裡。
    def eval_statement(node, scope)
      unless node.is_a?(Prism::CallNode) && node.receiver.nil?
        record(node, "只允許指令呼叫,不允許 #{describe(node)}")
      end

      entry = @registry.commands[node.name]
      unless entry
        record(node, "未知指令 `#{node.name}`(目前可用:#{@registry.commands.keys.join(", ")})")
      end

      validate_block(node, entry)
      ctx       = Context.new(self, scope, node)
      pos, kw   = split_args(node, scope)
      invoke(node, "指令", entry, [ctx, *pos], kw)
    end

    # 安全閘門二(遞迴、scope-aware):字面量/陣列/雜湊直接轉換;
    # 呼叫只放行「無 receiver、無區塊、名字在【函數註冊表】裡」者。
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

    # 把參數拆成「位置參數」與「尾隨關鍵字」(後者就是 host 接口的 kwargs)。
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

    # 一般雜湊值(顯式 {…}):只收 key => value 字面量對,拒絕 ** 展開。
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
    # handler 內部丟出的例外被收集成設定錯誤,不讓它炸掉整次載入。
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

    # 記下錯誤並跳出「當前這條語句」,讓走訪繼續找後面的錯。
    def record(node, message)
      @errors << "#{loc(node.location)} #{message}"
      throw :abort_statement
    end
  end
end
