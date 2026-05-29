# host 端(可信代碼):一套 DSL 就是一個 PrismDSL::Space 子類。
#
# Stage 12 重點:用 operator(sym){ |a,b| … } 由【host 決定能怎麼算】。看下面
# 的宣告 —— host 同時決定了哪些運算子存在、各自怎麼算、不開放什麼:
#   - + / -  直接算
#   - *      host 加了型別閘:只允許數值相乘,擋掉 "x"*10**9 / [0]*huge 記憶體炸彈
#   - / 與 ** 故意【不宣告】—— host 決定不開放(除零、指數計算炸彈)
# 引擎自己一行算術都不做,只把求好的 inert 運算元交給這些 body。
#
# (沿用前面:dsl_method 管暴露面/安全,type_check 管值型別/正確性,插值已開;
#  set/plugin/group 的 is_a? 檢查在 type_check;to_int/pool 靠 Integer() 強轉。)

require_relative "prism_dsl"

class AppConfig < PrismDSL::Space
  def initialize          # 自由寫,不必 super
    @values   = {}
    @plugins  = []
    @server   = nil
    @database = nil
  end

  # 結果出口:非動詞名,避免和 dsl_method 撞名;也不是 dsl_method ⇒ 輸入點不到。
  def to_h
    h = @values.dup
    h[:server]   = @server      if @server
    h[:plugins]  = @plugins unless @plugins.empty?
    h[:database] = @database    if @database
    h
  end

  # ── 值方法(用在參數位置,回傳值)──
  dsl_method(:env) { |name, fallback = nil| ENV.fetch(name.to_s, fallback) }
  type_check(:env, name: [String, Symbol], fallback: String)   # fallback 省略時不檢查

  dsl_method(:to_int) { |v| Integer(v) }          # 不宣告型別:靠 Integer() 自行強轉(opt-in 的反例)

  dsl_method(:ref) do |key|
    @values.fetch(key) { raise ArgumentError, "ref(:#{key}) 找不到 —— 只能參照本層之前設過的 key" }
  end
  type_check(:ref, key: Symbol)

  # ── 運算子(host 決定能怎麼算)──
  operator(:+) { |a, b| a + b }
  operator(:-) { |a, b| a - b }
  operator(:*) do |a, b|
    # host 自己定政策:只允許數值相乘,擋掉 "x"*10**9 / [0]*huge 這種記憶體炸彈。
    unless a.is_a?(Numeric) && b.is_a?(Numeric)
      raise ArgumentError, "`*` 只允許數值 × 數值(擋記憶體炸彈);不接受 #{a.class} * #{b.class}"
    end
    a * b
  end
  # 故意【不宣告】:/ 與 :**  —— host 決定不開放(除零、指數計算炸彈)

  # ── 指令方法(改 self 的狀態)──
  dsl_method(:set) { |key, value| @values[key] = value }   # 原本的 key.is_a?(Symbol) 檢查 → 移到 type_check
  type_check(:set, key: Symbol)                            # value 不限:set 收任意設定值

  dsl_method(:listen) { |host:, port:| @server = { host:, port: } }
  type_check(:listen, host: String, port: Integer)         # port: ref(:port) 也走這條 —— 查算出來的值

  dsl_method(:plugin) { |name, **opts| @plugins << { name:, **opts } }
  type_check(:plugin, name: Symbol)

  # ── 同詞彙巢狀(group):開一個自己的子空間,取它的 to_h 收進來 ──
  dsl_method(:group) do |name, &_|
    @values[name] = subspace(self.class).to_h   # 隔離:子空間有自己的 @values
  end
  type_check(:group, name: Symbol)

  # ── 換詞彙巢狀(database):開一個 DatabaseConfig,並【顯式向下】注入 app_env ──
  dsl_method(:database) { |&_| @database = subspace(DatabaseConfig, app_env: @values[:env]).to_h }

  # ── 普通 helper:沒 dsl_method ⇒ 解析輸入永遠點不到(即使是 public)──
  def secret_helper
    File.read("/etc/passwd")
  end
end

# 另一套詞彙 = 另一個 class。
class DatabaseConfig < PrismDSL::Space
  def initialize(app_env: "dev")
    @app_env = app_env
    @opts    = {}
  end

  def to_h = { app_env: @app_env, **@opts }

  dsl_method(:adapter) { |name| @opts[:adapter] = name }
  type_check(:adapter, name: String)

  dsl_method(:pool) { |n| @opts[:pool] = Integer(n) }   # 不宣告型別:靠 Integer() 強轉
end
