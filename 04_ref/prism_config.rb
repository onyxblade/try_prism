# Stage 4 — 受限參照 ref(:key) 的 Prism/AST 安全 config DSL
#
# 在 Stage 3(set/group + 陣列/雜湊值)之上,讓一個值能參照另一個已設定的值:
#     set :base, "https://example.com"
#     set :api,  ref(:base)
# 這是 DSL 第一次有「資料流」—— 值之間互相依賴。
#
# 設計上的取捨:
# * 只能「向後」參照(被參照的 key 必須在當前或外層作用域、且在此行之前已設定)。
#   → 自上而下走一遍即可求值,確定、無循環、無需多趟。
# * 沿作用域鏈往外層找(group 內可參照外層的 key),所以需要 Scope 帶 parent。
#
# 新的攻擊面:值的位置現在容許「呼叫」(因為 ref(...) 是一次呼叫)。
# 但白名單只認 ref 這一個名字、且不可帶 receiver/區塊;File.read、ENV[..]、
# system(..) 等仍一律拒絕。把「值裡能執行什麼」收斂成恰好一個函式。

require "prism"

module PrismConfig
  class RejectedError < StandardError; end

  # 巢狀作用域:data 是這一層產出的 Hash,parent 指向外層。
  # resolve 沿鏈往外找;區分「找不到」與「值剛好是 nil」用 NOT_FOUND 哨符。
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
    end

    def load
      result = Prism.parse(@source)
      unless result.success?
        details = result.errors.map { |e| "  #{loc(e.location)} #{e.message}" }
        raise RejectedError, "無法解析設定檔:\n#{details.join("\n")}"
      end

      root = Scope.new
      eval_statements(result.value.statements, root)
      root.data
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

    def eval_set(node, scope)
      reject(node, "`set` 不接受 do…end 區塊") if node.block
      args = node.arguments&.arguments || []
      unless args.size == 2
        reject(node, "`set` 需要 2 個參數(:key, value),收到 #{args.size} 個")
      end

      key = eval_value(args[0], scope)
      val = eval_value(args[1], scope)
      reject(args[0], "設定鍵必須是符號,例如 :port") unless key.is_a?(Symbol)
      scope[key] = val
    end

    def eval_group(node, scope)
      args = node.arguments&.arguments || []
      unless args.size == 1
        reject(node, "`group` 需要 1 個名稱參數(:name),收到 #{args.size} 個")
      end
      name = eval_value(args[0], scope)
      reject(args[0], "group 名稱必須是符號,例如 :database") unless name.is_a?(Symbol)

      block = node.block
      unless block.is_a?(Prism::BlockNode)
        reject(node, "`group` 需要一個 do…end 區塊")
      end
      reject(block, "group 區塊不接受參數(do |x| 不允許)") if block.parameters

      # 同名 group 可重開並沿用既有 Hash;子作用域以它為 data,可參照外層。
      existing = scope.data[name]
      child = scope.child(data: existing.is_a?(Hash) ? existing : {})
      eval_statements(block.body, child)
      scope[name] = child.data
    end

    # 安全閘門二(遞迴、scope-aware):把節點求成 Ruby 值。
    # 字面量直接轉換;陣列/雜湊遞迴;呼叫只放行 ref(:key)。
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
        reject(node, "不支援的值 #{describe(node)};只接受字面量、陣列、雜湊或 ref(:key)")
      end
    end

    def eval_hash(node, scope)
      node.elements.each_with_object({}) do |assoc, h|
        unless assoc.is_a?(Prism::AssocNode)
          reject(assoc, "雜湊裡不支援 #{describe(assoc)}(例如 ** 展開);只接受 key => value 字面量對")
        end
        key = eval_value(assoc.key, scope)
        val = eval_value(assoc.value, scope)
        h[key] = val
      end
    end

    # 值位置裡唯一放行的呼叫:ref(:key)。
    def eval_ref(node, scope)
      unless node.receiver.nil? && node.block.nil? && node.name == :ref
        reject(node, "值裡只允許 ref(:key) 這一種呼叫;不接受其他方法呼叫")
      end
      args = node.arguments&.arguments || []
      reject(node, "ref 需要 1 個符號參數,例如 ref(:host)") unless args.size == 1

      key = eval_value(args[0], scope)
      reject(args[0], "ref 的參數必須是符號,例如 ref(:host)") unless key.is_a?(Symbol)

      value = scope.resolve(key)
      if value.equal?(NOT_FOUND)
        reject(node, "ref(:#{key}) 找不到 —— 只能參照在它之前(同層或外層)已設定的 key")
      end
      value
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
