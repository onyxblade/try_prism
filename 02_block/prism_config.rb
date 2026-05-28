# Stage 2 — 巢狀區塊(group)的 Prism/AST 安全 config DSL
#
# 在 Stage 1(扁平 set)之上新增 `group :name do … end`,把設定分組成巢狀 Hash。
# 關鍵變化:走訪變成「遞迴」—— 每個 group 開一個新的子作用域(子 Hash),
# 在其中繼續走訪 set / group。子作用域就是巢狀結構的來源。
#
# 安全性質不變:仍然只是「解析 + 解讀」,從不執行 DSL。group 區塊裡若藏了
# system(...),它一樣只是個不認得的 CallNode,在該深度被拒絕。兩道閘門
# (eval_statement 名字白名單、literal 只收字面量)在每一層都照樣套用。

require "prism"

module PrismConfig
  class RejectedError < StandardError; end

  class SafeLoader
    def self.load(source, filename: "(config)")
      new(source, filename).load
    end

    def initialize(source, filename)
      @source   = source
      @filename = filename
    end

    def load
      result = Prism.parse(@source)
      unless result.success?
        details = result.errors.map { |e| "  #{loc(e.location)} #{e.message}" }
        raise RejectedError, "無法解析設定檔:\n#{details.join("\n")}"
      end

      root = {}
      eval_statements(result.value.statements, root)
      root
    end

    private

    # 走訪一個 StatementsNode 的每條語句,寫進指定作用域 scope。
    # group 會以新的子 scope 遞迴呼叫這裡 —— 這就是巢狀的來源。
    def eval_statements(statements, scope)
      return if statements.nil? # 空區塊:block.body 可能是 nil
      statements.body.each { |node| eval_statement(node, scope) }
    end

    # 安全閘門一:只允許無 receiver 的裸呼叫,再依名字白名單分派。
    def eval_statement(node, scope)
      unless node.is_a?(Prism::CallNode) && node.receiver.nil?
        reject(node, "只允許設定指令,不允許 #{describe(node)}")
      end

      case node.name
      when :set   then eval_set(node, scope)
      when :group then eval_group(node, scope)
      else
        reject(node, "未知指令 `#{node.name}`(支援 `set`、`group`)")
      end
    end

    # set :key, <字面量>
    def eval_set(node, scope)
      reject(node, "`set` 不接受 do…end 區塊") if node.block
      args = node.arguments&.arguments || []
      unless args.size == 2
        reject(node, "`set` 需要 2 個參數(:key, value),收到 #{args.size} 個")
      end

      key = literal(args[0])
      val = literal(args[1])
      reject(args[0], "設定鍵必須是符號,例如 :port") unless key.is_a?(Symbol)
      scope[key] = val
    end

    # group :name do … end → 在 scope 底下開一個巢狀 Hash,遞迴走訪其區塊。
    def eval_group(node, scope)
      args = node.arguments&.arguments || []
      unless args.size == 1
        reject(node, "`group` 需要 1 個名稱參數(:name),收到 #{args.size} 個")
      end
      name = literal(args[0])
      reject(args[0], "group 名稱必須是符號,例如 :database") unless name.is_a?(Symbol)

      block = node.block
      unless block.is_a?(Prism::BlockNode)
        reject(node, "`group` 需要一個 do…end 區塊")
      end
      reject(block, "group 區塊不接受參數(do |x| 不允許)") if block.parameters

      # 同名 group 可重開並合併,而非互相覆蓋。
      child = scope[name].is_a?(Hash) ? scope[name] : {}
      eval_statements(block.body, child)
      scope[name] = child
    end

    # 安全閘門二:值只接受字面量節點。任何運算/呼叫都不是字面量,在此被擋。
    def literal(node)
      case node
      when Prism::SymbolNode  then node.unescaped.to_sym
      when Prism::StringNode  then node.unescaped
      when Prism::IntegerNode then node.value
      when Prism::FloatNode   then node.value
      when Prism::TrueNode    then true
      when Prism::FalseNode   then false
      when Prism::NilNode     then nil
      else
        reject(node, "不支援的值 #{describe(node)};這裡只接受字面量")
      end
    end

    def describe(node)
      node.class.name.split("::").last.sub(/Node$/, "")
    end

    def loc(location)
      "#{@filename}:#{location.start_line}:#{location.start_column + 1}:"
    end

    def reject(node, message)
      raise RejectedError, "#{loc(node.location)} #{message}"
    end
  end
end
