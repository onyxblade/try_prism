# Stage 9 — 把 DSL 定義變成「一個 class」:最 Ruby 的作者介面
#
# 前八階段 host 用 dsl.command/dsl.function 註冊 proc(配置式 meta-DSL)。
# 這一階段換成:host 直接寫一個 PrismDSL::Space 子類 ——
#   - 用 dsl_method(name, **opts) { |…| … } 宣告詞彙(block 就是方法體);
#   - self 就是那個 DSL 空間,狀態放在作者自己的 ivar;
#   - Foo.parse do … end 解析(不執行!)那個 block,回傳 Space 實例本身。
#
# 安全模型不變,只是更乾淨:
#   - 白名單 = 明確 dsl_method 宣告的名字(opt-in、fail-closed);
#     普通 def helper 永遠不可被解析輸入觸及(即使是 public)。
#   - block 從不執行(沿用 Stage 7:用 source_location 定位、走訪解讀)。
#   - 值只接受字面量/陣列/雜湊/已宣告方法的呼叫;賦值、外層區域變數、
#     帶 receiver/block 的呼叫一律拒絕並指路。
#   - 巢狀 = body 裡 subspace(OtherSpace, **注入值):子空間與父級【隔離】,
#     跨界只能向下、顯式地透過 initialize 注入(同 Stage 8 的受控注入)。
#
# define_method ⇒ body 的 self 是實例、ivar 是狀態、arity/必需關鍵字照樣強制
# (少傳就 ArgumentError,被引擎接住轉成友善訊息)。引擎自己的簿記(父鏈、
# 當前節點)放在一個保留欄位 @__prism,作者的 initialize 完全自由、不必 super。

require "prism"

module PrismDSL
  class RejectedError < StandardError; end

  # ── 作者繼承這個類來定義一套 DSL ──
  class Space
    class << self
      def own_dsl_methods
        @own_dsl_methods ||= {}
      end

      # 宣告一個 DSL 方法。name 是詞彙;opts 先留著(之後放 position/巢狀/schema);
      # body 就是方法體 —— define_method 之後 self 是實例、ivar 是狀態。
      def dsl_method(name, **opts, &body)
        raise ArgumentError, "dsl_method(:#{name}) 需要一個方法體 block" unless body
        own_dsl_methods[name] = opts
        define_method(name, &body)
        name
      end

      # 沿繼承鏈合併(子類可覆寫/擴充父類詞彙)。只看 Space 血統,
      # Object/Kernel 的 send、instance_eval… 自動不在表內。
      def dsl_method_table
        table = {}
        ancestors.reverse_each do |mod|
          table.merge!(mod.own_dsl_methods) if mod.respond_to?(:own_dsl_methods)
        end
        table
      end

      def dsl_method?(name) = dsl_method_table.key?(name)
      def dsl_method_names  = dsl_method_table.keys

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
      space.send(node.name, *pos, **kw)
    rescue ArgumentError => e
      record(node, "`#{node.name}` 的參數不正確:#{e.message}")
    rescue RejectedError
      raise
    rescue => e
      record(node, "`#{node.name}` 執行失敗:#{e.message}")
    end

    def raise_if_errors!
      return if @errors.empty?
      listing = @errors.map { |e| "  #{e}" }.join("\n")
      raise RejectedError, "設定有 #{@errors.size} 個問題:\n#{listing}"
    end

    def describe(node) = node.class.name.split("::").last.sub(/Node$/, "")
    def loc(location)  = "#{@filename}:#{location.start_line}:#{location.start_column + 1}:"
  end
end
