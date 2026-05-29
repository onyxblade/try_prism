# Stage 14 — 帶 receiver 的呼叫:按【型別 stub】分派(每個型別自己的方法白名單)
#
# Stage 12 的 operator(:+) 是【全局】的 —— 對任何 receiver 都同一個定義,其實就是
# 「一個給所有型別共用的 stub」。這一階段把那個大袋子【按 receiver 的型別拆開】:
# host 為每個型別宣告一個 stub(一張方法表),`a.m(args)` 去查 a 的型別有沒有宣告
# m,沒有就拒。這正是 fail-closed 的 per-type 白名單 ——「stub 上未宣告的方法都
# 被拒絕」。它同時【收掉 Stage 12 的瑕疵】:`*` 的 body 以前要寫 `unless Numeric`
# 來決定「哪些型別能用 *」(把「哪些型別」混進了「怎麼算」);現在「哪些型別」=
# 「哪些 stub 宣告了 *」(宣告式),body 只管「怎麼算」。`"x" * big` 不再靠 runtime
# 檢查擋,而是「String stub 沒宣告 *」結構性地擋。
#
# 接口:stub(Type) { op(:name){ |recv, *args| … } }(取代 Stage 12 的全局 operator)。
#   - op 的名稱【不限】中綴運算子 —— 點方法 `s.upcase`、`s.length` 一樣宣告;
#   - body 第一個參數是 receiver,其餘是呼叫引數(`a + b` → recv=a, args=[b]);
#   - 沿 receiver 的 class.ancestors 查表 → 可宣告 stub Numeric 同時覆蓋 Integer/Float;
#   - 鏈式 `a.foo.bar` 自然支援:每一跳各自求值、各自查 stub、各自 fail-closed。
#
# 引擎自己一行運算都不做。看到帶 receiver 的呼叫:① 先【求值 receiver】(照樣走
# eval_value 全套防線 —— `File.read` 的 receiver 是常數 File,求值就死;`$g.x` 的
# receiver 是全域變數,也死);② 用 recv.class 查 host 的 stub 表,沒這個方法就拒;
# ③ 把 inert 的 recv 與引數交給 host 的 op body(`space.instance_exec`)。
#
# 沒有了 Stage 12 的 OPERATOR_SYMBOLS 全局底 —— per-type 白名單【本身就是底】。
# 唯一的新底是:不准對 Object / BasicObject / Kernel 這種太廣的根宣告 stub
# (否則等於替所有值開門)。
#
# 其餘(parse 不 eval、dsl_method 白名單、type_check、coerce、插值、括號、巢狀
# subspace、錯誤彙整)同前。
#
#   分工:dsl_method=暴露面(無 receiver 的指令/值方法)、stub=帶 receiver 的
#         方法(按型別)、coerce=正規化、type_check=驗證。

require "prism"

module PrismDSL
  class RejectedError < StandardError; end

  # 太廣的根:不准對它們宣告 stub —— 否則「帶 receiver 的呼叫」這道門等於對所有值
  # 大開(BasicObject#instance_eval 之類也會被掛進來)。host 只能對具體型別宣告。
  STUB_FORBIDDEN_ROOTS = [BasicObject, Object, Kernel].freeze

  # stub(Type){ … } 區塊裡的小 DSL:用 op(:name){ |recv,*args| … } 累積一張方法表。
  # 跟 dsl_method 不同——這裡的方法是【掛在某個型別上的】,經 receiver 分派。
  class StubBuilder
    attr_reader :table

    def initialize
      @table = {}
    end

    def op(name, &body)
      raise ArgumentError, "op 的名稱必須是符號(例如 op(:+))" unless name.is_a?(Symbol)
      raise ArgumentError, "op(#{name.inspect}) 需要一個 body block" unless body
      # body 至少要能收到 receiver(arity 0 連 receiver 都收不到);splat(負 arity)放行。
      if body.arity.zero?
        raise ArgumentError, "op(#{name.inspect}) 的 body 至少要收一個 receiver 參數 |recv, …|"
      end
      @table[name] = body
      name
    end
  end

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

      def own_stubs
        @own_stubs ||= {}
      end

      # 為某個【型別】宣告一個 stub:該型別的值上,哪些方法可呼叫、各自怎麼算
      # (取代 Stage 12 的全局 operator)。block 裡用 op(:name){ |recv,*args| … }。
      # 帶 receiver 的呼叫只認這裡宣告的方法 —— per-type 白名單就是底,fail-closed。
      def stub(type, &block)
        raise ArgumentError, "stub 的第一個參數必須是 Class/Module,得到 #{type.inspect}" unless type.is_a?(Module)
        if STUB_FORBIDDEN_ROOTS.include?(type)
          raise ArgumentError, "不可為 #{type} 宣告 stub(太廣,等於替所有值開門);請對具體型別宣告"
        end
        raise ArgumentError, "stub(#{type}) 需要一個 do…end 區塊" unless block
        builder = StubBuilder.new
        builder.instance_eval(&block)
        (own_stubs[type] ||= {}).merge!(builder.table)
        type
      end

      # 合併整條繼承鏈上各 Space 宣告的 stub:{ Type => { name => body } }。
      def stub_table
        table = {}
        ancestors.reverse_each do |mod|
          next unless mod.respond_to?(:own_stubs)
          mod.own_stubs.each { |type, methods| (table[type] ||= {}).merge!(methods) }
        end
        table
      end

      # 沿 value_class 的 ancestors(最具體者優先)找 name 的 body;找不到回 nil。
      # 所以 stub Numeric 能覆蓋 Integer/Float;Integer 上的同名方法蓋過 Numeric。
      def stub_method(value_class, name)
        table = stub_table
        value_class.ancestors.each do |anc|
          methods = table[anc]
          return methods[name] if methods&.key?(name)
        end
        nil
      end

      # value_class 在 stub 表裡【任一祖先】可用的全部方法名(供報錯列出)。
      def stub_methods_for(value_class)
        table = stub_table
        value_class.ancestors.flat_map { |anc| table[anc]&.keys || [] }.uniq
      end

      def own_coercions
        @own_coercions ||= {}
      end

      # 宣告某 DSL 方法的某些參數【求值後、驗型別前】要怎麼正規化(第四套接口)。
      # rules 形如 { key: ->(v){…}, name: ->(v){…} }:每個 coercer 收【已求值的】
      # 單一值,回傳折好的值。典型用途是統一 string 與 symbol。引擎自己不折任何
      # 東西,只跑 host 寫的這些 coercer。必須先 dsl_method 宣告該方法,且只能對
      # 真有的具名參數宣告(跟 type_check 同一套作者期檢查)。
      def coerce(name, **rules)
        unless method_defined?(name) || private_method_defined?(name)
          raise ArgumentError, "coerce(:#{name}):請先用 dsl_method(:#{name}) 宣告這個方法"
        end
        valid = instance_method(name).parameters
                  .select { |kind, _| %i[req opt keyreq key].include?(kind) }
                  .map { |_, pname| pname }
        rules.each do |pname, coercer|
          unless valid.include?(pname)
            raise ArgumentError,
                  "coerce(:#{name}) 宣告了未知參數 `#{pname}`(這個方法的具名參數:#{valid.join(", ")})"
          end
          unless coercer.respond_to?(:call) && coercer.respond_to?(:arity) && coercer.arity == 1
            raise ArgumentError,
                  "coerce(:#{name}) 的 `#{pname}` 需要一個收【單一值】的可呼叫物(例如 ->(v){ … })"
          end
        end
        (own_coercions[name] ||= {}).merge!(rules)
        name
      end

      def coercion_table
        table = {}
        ancestors.reverse_each do |mod|
          next unless mod.respond_to?(:own_coercions)
          mod.own_coercions.each { |name, rules| (table[name] ||= {}).merge!(rules) }
        end
        table
      end

      def coercion_for(name) = coercion_table[name]

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
      when Prism::ParenthesesNode then eval_parentheses(node, frame)
      when Prism::CallNode    then eval_value_call(node, frame)
      when Prism::LocalVariableReadNode
        record(node, "`#{node.name}` 是外層區域變數;這個區塊不會執行,拿不到它。" \
                     "要用外部值,請在 parse/subspace 傳入,並在 initialize 接收")
      else
        record(node, "不支援的值 #{describe(node)};只接受字面量、陣列、雜湊,或已宣告方法的呼叫")
      end
    end

    def eval_value_call(node, frame)
      # 帶 receiver 的呼叫(`a + b`、`a.upcase`、File.read…)→ 按 receiver 的型別 stub 分派。
      return eval_method_on(node, frame) unless node.receiver.nil?

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

    # 括號 (expr) 只是分組,拆開求裡頭那個運算式(讓 (a + 1) * 8 這種能寫)。
    def eval_parentheses(node, frame)
      stmts = node.body&.body || []
      record(node, "() 裡只允許剛好一個運算式") unless stmts.length == 1
      eval_value(stmts.first, frame)
    end

    # 帶 receiver 的呼叫 `recv.name(args)`(含中綴 `a + b`),按 receiver 的型別 stub
    # 分派。引擎自己一行運算都不做:① 先【求值 receiver】—— 照樣走 eval_value 全套
    # 防線,所以 File 常數 / 全域變數 / 未宣告方法當 receiver 都在這一步就死;
    # ② 用 recv.class 沿 ancestors 查 host 的 stub,沒這個方法就拒(fail-closed);
    # ③ 把 inert 的 recv 與引數交給 host 的 op body。鏈式 a.foo.bar 自然成立 ——
    # 內層 a.foo 也是這條路求出的值,再當外層的 receiver。
    def eval_method_on(node, frame)
      recv  = eval_value(node.receiver, frame)   # receiver 先求值(常數/全域/未宣告方法死在這)
      klass = frame.space.class
      name  = node.name

      record(node, "帶 receiver 的呼叫不可帶區塊(do…end 或 { })") unless node.block.nil?

      body = klass.stub_method(recv.class, name)
      if body.nil?
        avail = klass.stub_methods_for(recv.class)
        if avail.empty?
          record(node, "#{recv.class} 沒有任何可呼叫方法(host 沒為這個型別宣告 stub);" \
                       "帶 receiver 的呼叫只能用 host 為該型別 stub 宣告的方法")
        else
          record(node, "#{recv.class} 沒有宣告方法 `#{name}`;該型別 stub 只有:#{avail.join(' ')}")
        end
      end

      pos, kw = split_args(node, frame)          # 引數同樣走 eval_value 全套防線
      record(node, "`#{name}`(帶 receiver 的呼叫)目前只支援位置引數") unless kw.empty?
      if body.arity >= 0
        expected = body.arity - 1                # 扣掉 receiver 那一格
        unless pos.length == expected
          record(node, "`#{name}` 預期 #{expected} 個引數(receiver 之外),卻給了 #{pos.length} 個")
        end
      end

      apply_stub_method(node, frame.space, recv, name, pos, body)
    end

    # 把 inert 的 receiver 與引數交給 host 的 op body(self = space,跟 dsl_method 一致)。
    # body 裡 host 自訂的型別閘 / 除零 / 失敗若 raise,在這裡被接住、記成錯誤。
    def apply_stub_method(node, space, recv, name, args, body)
      space.instance_exec(recv, *args, &body)
    rescue RejectedError
      raise
    rescue => e
      record(node, "呼叫 `#{describe_value(recv)}.#{name}` 失敗:#{e.message}")
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
      pos, kw = coerce_args(node, space, pos, kw) # 先正規化(host 決定,例如統一 string/symbol)
      check_types(node, space, pos, kw)           # 再驗型別(record 會 throw,跳過下面的呼叫)
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

    # 求值後、驗型別前:套用 host 為各參數宣告的 coercer(正規化)。引擎自己不折
    # 任何值,只把【已求值的 inert 值】交給 host 的 coercer,拿回折好的值寫回去。
    # 只動有宣告 coercer 的具名參數;其餘原樣。回傳新的 [pos, kw]。
    def coerce_args(node, space, pos, kw)
      rules = space.class.coercion_for(node.name)
      return [pos, kw] if rules.nil? || rules.empty?

      pos = pos.dup
      kw  = kw.dup
      i   = 0
      space.class.instance_method(node.name).parameters.each do |kind, pname|
        case kind
        when :req, :opt
          pos[i] = apply_coercion(node, space, pname, rules[pname], pos[i]) if rules.key?(pname) && i < pos.length
          i += 1
        when :keyreq, :key
          kw[pname] = apply_coercion(node, space, pname, rules[pname], kw[pname]) if rules.key?(pname) && kw.key?(pname)
        end
      end
      [pos, kw]
    end

    # 跑 host 寫的單個 coercer(self = space,跟 dsl_method / stub op 一致)。
    # coercer 若 raise(例如對奇怪型別硬轉失敗),在這裡被接住記成錯誤。
    def apply_coercion(node, space, pname, coercer, value)
      space.instance_exec(value, &coercer)
    rescue RejectedError
      raise
    rescue => e
      record(node, "正規化 `#{node.name}` 的參數 `#{pname}`(#{describe_value(value)})失敗:#{e.message}")
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
