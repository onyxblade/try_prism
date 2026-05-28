# Stage 3 — 更多值型別(陣列/雜湊)的 Prism/AST 安全 config DSL
#
# 在 Stage 2(set + 巢狀 group)之上,讓「值」可以是陣列 [..] 與雜湊 {..},
# 並可任意巢狀。關鍵演進:`literal` 從「平面 case」變成「遞迴」——
# 陣列的每個元素、雜湊的每個 key/value 都重新走一次 literal。
#
# 新的攻擊面:值能巢狀,任意程式碼可以藏進陣列/雜湊深處
# (例如 set :tags, ["ok", system("...")] 或 { pw: ENV["X"] })。
# 但因為遞迴在每一層都套用同一道「只收字面量」閘門,非字面量在任何深度
# 都會被拒絕 —— 安全性質隨型別變豐富而不退化。

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

    def eval_statements(statements, scope)
      return if statements.nil?
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

    # set :key, <值>。值現在可以是字面量、陣列、或雜湊(可巢狀)。
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

      child = scope[name].is_a?(Hash) ? scope[name] : {}
      eval_statements(block.body, child)
      scope[name] = child
    end

    # 安全閘門二(現在是遞迴的):把字面量節點轉成 Ruby 值。
    # 陣列/雜湊會對每個子節點再呼叫 literal —— 任何非字面量在此被擋。
    def literal(node)
      case node
      when Prism::SymbolNode  then node.unescaped.to_sym
      when Prism::StringNode  then node.unescaped
      when Prism::IntegerNode then node.value
      when Prism::FloatNode   then node.value
      when Prism::TrueNode    then true
      when Prism::FalseNode   then false
      when Prism::NilNode     then nil
      when Prism::ArrayNode   then literal_array(node)
      # HashNode 是 { .. };KeywordHashNode 是裸關鍵字 set :x, a: 1。兩者同形。
      when Prism::HashNode, Prism::KeywordHashNode then literal_hash(node)
      else
        reject(node, "不支援的值 #{describe(node)};只接受字面量(字串/數字/符號/true/false/nil/陣列/雜湊)")
      end
    end

    def literal_array(node)
      # [1, *foo] 裡的 *foo 是 SplatNode,不是字面量 → literal 會在 else 拒絕。
      node.elements.map { |el| literal(el) }
    end

    def literal_hash(node)
      node.elements.each_with_object({}) do |assoc, h|
        unless assoc.is_a?(Prism::AssocNode)
          # { **other } 的 **other 是 AssocSplatNode。
          reject(assoc, "雜湊裡不支援 #{describe(assoc)}(例如 ** 展開);只接受 key => value 字面量對")
        end
        key = literal(assoc.key)
        val = literal(assoc.value)
        h[key] = val
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
