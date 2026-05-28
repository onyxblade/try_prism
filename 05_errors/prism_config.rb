# Stage 5 — 錯誤彙整(一次回報全部)的 Prism/AST 安全 config DSL
#
# 在 Stage 4 之上,把「遇到第一個違規就拋例外中止」改成「收集所有違規,
# 走完整棵樹後一次回報」。改的是控制流,不是安全閘門 —— 規則一字未動。
#
# 做法:編譯器式的錯誤復原。每條語句外面包一層 catch(:abort_statement);
# 違規時 record 把訊息記下並 throw,跳出「當前這條語句」,迴圈繼續下一條。
# → 一條壞語句報一個錯,然後恢復,繼續尋找後面的錯。group 內的語句各自有
#   自己的語句邊界,所以恢復粒度可以深入巢狀區塊。
#
# 注意:彙整全程仍只是「解析 + 檢視」。即使一份檔案塞滿 system(...)、
# File.read(...),也只是被收集成一串拒絕訊息 —— 沒有任何一行被執行。

require "prism"

module PrismConfig
  class RejectedError < StandardError; end

  NOT_FOUND = Object.new.freeze

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

  class SafeLoader
    def self.load(source, filename: "(config)")
      new(source, filename).load
    end

    def initialize(source, filename)
      @source   = source
      @filename = filename
      @errors   = []
    end

    def load
      result = Prism.parse(@source)
      # 語法錯誤:Prism 本來就會一次給出全部,直接回報。
      unless result.success?
        parse_errs = result.errors.map { |e| "  #{loc(e.location)} #{e.message}" }
        raise RejectedError, "無法解析設定檔(語法錯誤):\n#{parse_errs.join("\n")}"
      end

      root = Scope.new
      eval_statements(result.value.statements, root)

      # 語意錯誤:走完整棵樹後,一次回報所有收集到的問題。
      unless @errors.empty?
        listing = @errors.map { |e| "  #{e}" }.join("\n")
        raise RejectedError, "設定檔有 #{@errors.size} 個問題:\n#{listing}"
      end
      root.data
    end

    private

    # 每條語句包一層 catch:壞語句被跳過,迴圈繼續下一條 —— 這就是錯誤復原。
    def eval_statements(statements, scope)
      return if statements.nil?
      statements.body.each do |node|
        catch(:abort_statement) { eval_statement(node, scope) }
      end
    end

    # 安全閘門一:只允許無 receiver 的裸呼叫,再依名字白名單分派。
    def eval_statement(node, scope)
      unless node.is_a?(Prism::CallNode) && node.receiver.nil?
        record(node, "只允許設定指令,不允許 #{describe(node)}")
      end

      case node.name
      when :set   then eval_set(node, scope)
      when :group then eval_group(node, scope)
      else
        record(node, "未知指令 `#{node.name}`(支援 `set`、`group`)")
      end
    end

    def eval_set(node, scope)
      record(node, "`set` 不接受 do…end 區塊") if node.block
      args = node.arguments&.arguments || []
      unless args.size == 2
        record(node, "`set` 需要 2 個參數(:key, value),收到 #{args.size} 個")
      end

      key = eval_value(args[0], scope)
      val = eval_value(args[1], scope)
      record(args[0], "設定鍵必須是符號,例如 :port") unless key.is_a?(Symbol)
      scope[key] = val
    end

    def eval_group(node, scope)
      args = node.arguments&.arguments || []
      unless args.size == 1
        record(node, "`group` 需要 1 個名稱參數(:name),收到 #{args.size} 個")
      end
      name = eval_value(args[0], scope)
      record(args[0], "group 名稱必須是符號,例如 :database") unless name.is_a?(Symbol)

      block = node.block
      unless block.is_a?(Prism::BlockNode)
        record(node, "`group` 需要一個 do…end 區塊")
      end
      record(block, "group 區塊不接受參數(do |x| 不允許)") if block.parameters

      existing = scope.data[name]
      child = scope.child(data: existing.is_a?(Hash) ? existing : {})
      eval_statements(block.body, child)
      scope[name] = child.data
    end

    # 安全閘門二(遞迴、scope-aware):字面量直接轉換;陣列/雜湊遞迴;
    # 呼叫只放行 ref(:key)。
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
      when Prism::CallNode    then eval_ref(node, scope)
      else
        record(node, "不支援的值 #{describe(node)};只接受字面量、陣列、雜湊或 ref(:key)")
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

    def eval_ref(node, scope)
      unless node.receiver.nil? && node.block.nil? && node.name == :ref
        record(node, "值裡只允許 ref(:key) 這一種呼叫;不接受其他方法呼叫")
      end
      args = node.arguments&.arguments || []
      record(node, "ref 需要 1 個符號參數,例如 ref(:host)") unless args.size == 1

      key = eval_value(args[0], scope)
      record(args[0], "ref 的參數必須是符號,例如 ref(:host)") unless key.is_a?(Symbol)

      value = scope.resolve(key)
      if value.equal?(NOT_FOUND)
        record(node, "ref(:#{key}) 找不到 —— 只能參照在它之前(同層或外層)已設定的 key")
      end
      value
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
