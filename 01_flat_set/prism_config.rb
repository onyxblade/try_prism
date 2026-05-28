# Stage 1 — 用 Prism 解析 AST 的「安全」config DSL
#
# 核心想法:不「執行」DSL,而是把它「解析」成 AST,再由我們自己解讀。
# 只認得明確支援的節點(目前:頂層的 `set :key, <字面量>`),其餘一律拒絕。
#
# 因此即使檔案裡寫了 system("rm -rf ~"),那也只是樹上一個我們不認得的
# CallNode —— 直接報錯,而非被執行。這就是相對 method based(instance_eval)
# 版本最大的差別:不可信輸入也能安全餵進來。

require "prism"

module PrismConfig
  # 遇到不被允許的語法時拋出。
  class RejectedError < StandardError; end

  class SafeLoader
    def self.load(source, filename: "(config)")
      new(source, filename).load
    end

    def initialize(source, filename)
      @source   = source
      @filename = filename
      @settings = {}
    end

    def load
      result = Prism.parse(@source)

      # (1) 連 Ruby 語法都不合法 → 直接擋,附上 Prism 給的精準位置。
      unless result.success?
        details = result.errors.map { |e| "  #{loc(e.location)} #{e.message}" }
        raise RejectedError, "無法解析設定檔:\n#{details.join("\n")}"
      end

      # (2) 逐一解讀頂層語句。result.value 是 ProgramNode,
      #     .statements 是 StatementsNode,.body 是節點陣列。
      result.value.statements.body.each { |node| eval_statement(node) }
      @settings
    end

    private

    # 頂層只允許一種形狀:不帶 receiver、不帶 block 的方法呼叫(=指令)。
    # 例如 `set ...` 是;`foo.bar`、`x = 1`、`if ...` 都不是。
    def eval_statement(node)
      unless node.is_a?(Prism::CallNode) && node.receiver.nil? && node.block.nil?
        reject(node, "只允許設定指令,不允許 #{describe(node)}")
      end

      case node.name
      when :set then eval_set(node)
      else
        reject(node, "未知指令 `#{node.name}`(目前只支援 `set`)")
      end
    end

    # set :key, <字面量>
    def eval_set(node)
      args = node.arguments&.arguments || []
      unless args.size == 2
        reject(node, "`set` 需要 2 個參數(:key, value),收到 #{args.size} 個")
      end

      key = literal(args[0])
      val = literal(args[1])
      reject(args[0], "設定鍵必須是符號,例如 :port") unless key.is_a?(Symbol)

      @settings[key] = val
    end

    # 只把「字面量」節點轉成 Ruby 值。
    # 任何運算、方法呼叫、變數參照…… 都不是字面量,會在這裡被擋下。
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

    # 把 Prism 節點類名變成易讀的描述,例如 Prism::IfNode → "If"。
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
