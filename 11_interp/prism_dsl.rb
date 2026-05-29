# Stage 11 — 受限表達式:字串插值(第一道在「值層」放開的計算)
#
# 在 Stage 10 之上,值層只認字面量 / 容器 / 裸呼叫(env、ref、to_int),且有
# 一道硬牆:值裡的呼叫不可帶 receiver。這道牆順手也擋掉了 `"#{host}:#{port}"`
# —— 因為插值字串是個 InterpolatedStringNode,連 case 都沒進到就被 else 拒絕。
# 配置卻常需要拼字串(URL、路徑、連線字串),所以這一階段在牆上鑿第一個
# 形狀固定的洞:【字串插值】。
#
# 安全心法:不開放任意 `recv.method(args)`(那等於把 instance_eval 放回來),
# 而是手寫一個封閉求值器,只認 InterpolatedStringNode 這一種形狀。關鍵在於
# 每個 #{...} 內嵌運算式【照樣丟回 eval_value】——所以它自動繼承全套防線:
#   - #{File.read(...)} → 帶 receiver,被既有的牆擋
#   - #{secret_helper} → 未宣告方法,被白名單擋
#   - #{some_local}    → 外層區域變數,被既有規則擋
#   - "#@ivar" / "#$g" → EmbeddedVariableNode,明確擋掉
# 我們只負責把各段【已是 inert 值】的結果 to_s 後 join。
#
# 跟 type_check 的呼應:插值結果【必為 String】,丟進某個 position 後一樣走
# 「求值後型別檢查」—— 跟字面量、ref 完全同一條路。表達式只是第四種「產生
# 值的方式」,塞進來零摩擦(延續 Stage 10「求值後一視同仁」那個洞見)。
#
# 其餘(parse 不 eval、白名單、type_check、巢狀 subspace、錯誤彙整)同前。

require "prism"

module PrismDSL
  class RejectedError < StandardError; end

  # ── 作者繼承這個類來定義一套 DSL ──
  class Space
    class << self
      def own_dsl_methods
        @own_dsl_methods ||= {}
      end

      # 宣告一個 DSL 方法(暴露面 / 信任邊界)。body 就是方法體 ——
      # define_method 之後 self 是實例、ivar 是狀態、arity 照樣強制。
      def dsl_method(name, **opts, &body)
        raise ArgumentError, "dsl_method(:#{name}) 需要一個方法體 block" unless body
        own_dsl_methods[name] = opts
        define_method(name, &body)
        name
      end

      def dsl_method_table
        table = {}
        ancestors.reverse_each do |mod|
          table.merge!(mod.own_dsl_methods) if mod.respond_to?(:own_dsl_methods)
        end
        table
      end

      def dsl_method?(name) = dsl_method_table.key?(name)
      def dsl_method_names  = dsl_method_table.keys

      def own_type_specs
        @own_type_specs ||= {}
      end

      # 宣告某個 DSL 方法各參數的期望型別(正確性,跟 dsl_method 分開的一套)。
      # specs 形如 { host: String, port: Integer, value: [String, Integer] }:
      # 型別可以是 Class/Module、它們的陣列(任一即可)、:any(不限)、:bool。
      # 必須先 dsl_method 宣告該方法;且只能對真有的具名參數宣告。
      def type_check(name, **specs)
        unless method_defined?(name) || private_method_defined?(name)
          raise ArgumentError, "type_check(:#{name}):請先用 dsl_method(:#{name}) 宣告這個方法"
        end
        valid = instance_method(name).parameters
                  .select { |kind, _| %i[req opt keyreq key].include?(kind) }
                  .map { |_, pname| pname }
        specs.each_key do |pname|
          next if valid.include?(pname)
          raise ArgumentError,
                "type_check(:#{name}) 宣告了未知參數 `#{pname}`(這個方法的具名參數:#{valid.join(", ")})"
        end
        own_type_specs[name] = specs
        name
      end

      def type_spec_table
        table = {}
        ancestors.reverse_each do |mod|
          table.merge!(mod.own_type_specs) if mod.respond_to?(:own_type_specs)
        end
        table
      end

      def type_spec_for(name) = type_spec_table[name]

      # 入口:解析(非執行)傳入的 block,回傳建好的 Space 實例。
      def parse(*args, **kwargs, &block)
        Interpreter.new(self).run(args, kwargs, block)
      end
    end

    # ── 以下是 dsl_method body 內可用的(私有)helper ──
    private

    # 開一個子空間:用「當前指令的 do…end 區塊」的 AST,以另一套(或同一套)
    # 詞彙走一遍,回傳建好的子 Space。injected 是【顯式向下傳】的注入值,
    # 由子類的 initialize 宣告接受 —— 子空間看不到父級狀態(隔離)。
    def subspace(space_class, *args, **injected)
      frame = __prism
      block = frame.node.block
      unless block.is_a?(Prism::BlockNode)
        frame.interp.record(frame.node, "`#{frame.node.name}` 需要一個 do…end 區塊才能開子空間")
      end
      frame.interp.build_space(space_class, args, injected, block, "子空間 #{space_class}")
    end

    def __prism
      @__prism or raise RejectedError, "subspace 只能在 dsl_method 執行期間呼叫"
    end
  end

  # 每個 Space 實例配一個 Frame:存引擎與「當前正在分派的節點」,
  # 放在實例的保留欄位 @__prism,不碰作者的 ivar 命名空間。
  Frame = Struct.new(:interp, :space, :node)

  class Interpreter
    def initialize(space_class)
      @space_class = space_class
      @errors      = []
    end

    def run(args, kwargs, block)
      raise ArgumentError, "parse 需要一個區塊" unless block
      file, line = block.source_location
      unless file && File.readable?(file)
        raise RejectedError, "拿不到區塊原始碼(可能在 eval/IRB);inline DSL 需要可讀的原始檔"
      end
      @filename = file
      result    = parse_source(File.read(file))
      entry     = find_entry_block(result.value, line)
      raise RejectedError, "在 #{file}:#{line} 找不到對應的 parse 區塊" unless entry

      space = build_space(@space_class, args, kwargs, entry, "頂層 parse")
      raise_if_errors!
      space
    end

    # 供 Space#subspace 與 run 共用:建一個 Space,把 block body 走一遍。
    def build_space(space_class, args, kwargs, block_node, where)
      body  = body_of(block_node, where)
      space = space_class.new(*args, **kwargs)
      frame = Frame.new(self, space, nil)
      space.instance_variable_set(:@__prism, frame)
      begin
        eval_statements(body, frame)
      ensure
        space.remove_instance_variable(:@__prism) # 回傳的物件保持乾淨
      end
      space
    end

    # 供 Space#subspace 記錄結構性錯誤(會 throw,中止當前語句)。
    def record(node, message)
      @errors << "#{loc(node.location)} #{message}"
      throw :abort_statement
    end

    private

    def parse_source(source)
      result = Prism.parse(source)
      unless result.success?
        errs = result.errors.map { |e| "  #{loc(e.location)} #{e.message}" }
        raise RejectedError, "無法解析(語法錯誤):\n#{errs.join("\n")}"
      end
      result
    end

    def body_of(block_node, where)
      if block_node.parameters
        raise RejectedError, "#{where}的區塊不接受參數(do |x|);要注入外部值,請在 parse/subspace 傳入," \
                             "由類別的 initialize 宣告接受什麼"
      end
      block_node.body
    end

    def find_entry_block(root, line)
      found = nil
      visit = lambda do |node|
        return if found || !node.is_a?(Prism::Node)
        if node.is_a?(Prism::CallNode) && node.name == :parse &&
           node.block.is_a?(Prism::BlockNode) && node.block.location.start_line == line
          found = node.block
          return
        end
        node.compact_child_nodes.each { |c| visit.call(c) }
      end
      visit.call(root)
      found
    end

    def eval_statements(statements, frame)
      return if statements.nil?
      statements.body.each do |node|
        catch(:abort_statement) { eval_statement(node, frame) }
      end
    end

    def eval_statement(node, frame)
      unless node.is_a?(Prism::CallNode) && node.receiver.nil?
        message =
          if describe(node).end_with?("Write")
            "不允許賦值(=);這個區塊不會被執行,只接受指令呼叫"
          else
            "只允許指令呼叫,不允許 #{describe(node)}"
          end
        record(node, message)
      end

      klass = frame.space.class
      unless klass.dsl_method?(node.name)
        record(node, "未知指令 `#{node.name}`(可用:#{klass.dsl_method_names.join(", ")})")
      end

      pos, kw = split_args(node, frame)
      frame.node = node # split_args 之後再設,供 subspace 取本語句的 block
      invoke(node, frame.space, pos, kw)
    end

    def eval_value(node, frame)
      case node
      when Prism::SymbolNode  then node.unescaped.to_sym
      when Prism::StringNode  then node.unescaped
      when Prism::IntegerNode then node.value
      when Prism::FloatNode   then node.value
      when Prism::TrueNode    then true
      when Prism::FalseNode   then false
      when Prism::NilNode     then nil
      when Prism::ArrayNode   then node.elements.map { |el| eval_value(el, frame) }
      when Prism::HashNode, Prism::KeywordHashNode then eval_hash(node, frame)
      when Prism::InterpolatedStringNode then eval_interpolation(node, frame)
      when Prism::CallNode    then eval_value_call(node, frame)
      when Prism::LocalVariableReadNode
        record(node, "`#{node.name}` 是外層區域變數;這個區塊不會執行,拿不到它。" \
                     "要用外部值,請在 parse/subspace 傳入,並在 initialize 接收")
      else
        record(node, "不支援的值 #{describe(node)};只接受字面量、陣列、雜湊,或已宣告方法的呼叫")
      end
    end

    def eval_value_call(node, frame)
      unless node.receiver.nil?
        record(node, "值裡的呼叫不可帶 receiver(例如 File.read(...)、env(...).split);只允許 f(...) 這種裸呼叫")
      end
      unless node.block.nil?
        record(node, "值裡的呼叫不可帶區塊(do…end 或 { })")
      end
      klass = frame.space.class
      unless klass.dsl_method?(node.name)
        record(node, "未宣告的方法 `#{node.name}`;值裡只能用已宣告的方法(目前:#{klass.dsl_method_names.join(", ")})")
      end
      pos, kw = split_args(node, frame)
      invoke(node, frame.space, pos, kw)
    end

    # 受限表達式之一:字串插值。我們不執行字串,而是把它拆成「字面段」與
    # 「#{...} 段」,各自求值後 to_s 再 join。結果【必為 String】。
    # 每個 #{...} 內嵌運算式照樣丟回 eval_value,自動繼承全套防線。
    def eval_interpolation(node, frame)
      node.parts.map { |part| eval_interp_part(part, frame) }.join
    end

    def eval_interp_part(part, frame)
      case part
      when Prism::StringNode
        part.unescaped                              # 字面段,例如 "redis://"、":"
      when Prism::EmbeddedStatementsNode
        stmts = part.statements&.body || []
        return "" if stmts.empty?                   # "#{}" → 空字串
        if stmts.length > 1
          record(part, "插值 \#{...} 裡只允許單一運算式,不允許多個陳述句")
        end
        eval_value(stmts.first, frame).to_s         # #{...} 段:遞迴求值再 to_s
      when Prism::EmbeddedVariableNode
        record(part, "字串插值不可內嵌 \#@ivar / \#$global / \#@@cvar 這種變數;" \
                     "\#{...} 裡只能放字面量,或已宣告方法的呼叫")
      else
        record(part, "字串插值不支援 #{describe(part)}")
      end
    end

    def split_args(node, frame)
      arg_nodes  = (node.arguments&.arguments || []).dup
      kw_node    = arg_nodes.last.is_a?(Prism::KeywordHashNode) ? arg_nodes.pop : nil
      positional = arg_nodes.map { |n| eval_value(n, frame) }
      kwargs     = kw_node ? eval_kwargs(kw_node, frame) : {}
      [positional, kwargs]
    end

    def eval_kwargs(node, frame)
      node.elements.each_with_object({}) do |assoc, h|
        unless assoc.is_a?(Prism::AssocNode) && assoc.key.is_a?(Prism::SymbolNode)
          record(assoc, "關鍵字參數的鍵必須是符號,例如 host:")
        end
        h[assoc.key.unescaped.to_sym] = eval_value(assoc.value, frame)
      end
    end

    def eval_hash(node, frame)
      node.elements.each_with_object({}) do |assoc, h|
        unless assoc.is_a?(Prism::AssocNode)
          record(assoc, "雜湊裡不支援 #{describe(assoc)}(例如 ** 展開);只接受 key => value")
        end
        h[eval_value(assoc.key, frame)] = eval_value(assoc.value, frame)
      end
    end

    def invoke(node, space, pos, kw)
      check_types(node, space, pos, kw) # 求值後、送進 body 前先驗型別(record 會 throw,跳過下面的呼叫)
      begin
        space.send(node.name, *pos, **kw)
      rescue ArgumentError => e
        record(node, "`#{node.name}` 的參數不正確:#{e.message}")
      rescue RejectedError
        raise
      rescue => e
        record(node, "`#{node.name}` 執行失敗:#{e.message}")
      end
    end

    # 把宣告的型別對回求值後的引數,逐一檢查。一個呼叫的多個型別問題一次收齊
    # 再 throw(所以 listen 的 host 和 port 都錯時,兩個都會報)。
    def check_types(node, space, pos, kw)
      specs = space.class.type_spec_for(node.name)
      return if specs.nil? || specs.empty?

      bound    = bind_named(space.class.instance_method(node.name).parameters, pos, kw)
      problems = []
      specs.each do |pname, type|
        next unless bound.key?(pname) # 沒傳(可選參數省略)→ 不檢查;少必填讓 send 去報 ArgumentError
        value = bound[pname]
        next if type_match?(value, type)
        problems << "`#{pname}` 期望 #{describe_type(type)},卻得到 #{describe_value(value)}"
      end
      return if problems.empty?

      problems.each { |p| @errors << "#{loc(node.location)} `#{node.name}` 的 #{p}" }
      throw :abort_statement
    end

    # 用 parameters 把求值後的 pos/kw 對回參數名。
    def bind_named(parameters, pos, kw)
      bound = {}
      i = 0
      parameters.each do |kind, pname|
        case kind
        when :req, :opt
          bound[pname] = pos[i] if i < pos.length
          i += 1
        when :keyreq, :key
          bound[pname] = kw[pname] if kw.key?(pname)
        end
      end
      bound
    end

    def type_match?(value, type)
      case type
      when :any   then true
      when :bool  then value == true || value == false
      when Array  then type.any? { |t| type_match?(value, t) }
      when Module then value.is_a?(type)
      else
        raise ArgumentError, "type_check 不支援的型別宣告:#{type.inspect}(用 Class/Module、其陣列、:any 或 :bool)"
      end
    end

    def describe_type(type)
      case type
      when :any   then "任意值"
      when :bool  then "true/false"
      when Array  then type.map { |t| describe_type(t) }.join(" 或 ")
      when Module then type.name
      else type.inspect
      end
    end

    def describe_value(value) = "#{value.class}(#{value.inspect})"

    def raise_if_errors!
      return if @errors.empty?
      listing = @errors.map { |e| "  #{e}" }.join("\n")
      raise RejectedError, "設定有 #{@errors.size} 個問題:\n#{listing}"
    end

    def describe(node) = node.class.name.split("::").last.sub(/Node$/, "")
    def loc(location)  = "#{@filename}:#{location.start_line}:#{location.start_column + 1}:"
  end
end
