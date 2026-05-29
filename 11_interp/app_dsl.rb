# host 端(可信代碼):一套 DSL 就是一個 PrismDSL::Space 子類。
#
# Stage 11 重點:值層放開了【字串插值】。注意這個檔【一行都不用改】——
# 插值純粹是引擎能力,host 不必多暴露任何方法:`set` 照收任意值(可以是
# 插值出來的字串),`listen host: String` 正好接插值結果。放開計算 ≠ 擴大
# 暴露面,這正是「受限表達式」的意思。
#
# (沿用 Stage 10:dsl_method 管暴露面/安全,type_check 管值型別/正確性;
#  set/plugin/group 的 is_a? 檢查已收進 type_check;to_int/pool 故意不宣告
#  型別,靠 Integer() 自行強轉,示範 opt-in。)

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
