# host 端(可信代碼):一套 DSL 就是一個 PrismDSL::Space 子類。
#
# 對照 Stage 6-8 的 dsl.command/dsl.function 註冊 —— 這裡整套詞彙就是
# 「你定義的方法」。self 是空間、ivar 是狀態、dsl_method 宣告暴露面。
# 沒有任何內建 set/group/ref:全部由作者用普通方法砌出來(更通用)。
#
# 注意一個 ivar 模型的自然後果:DSL 動詞(dsl_method)和「讀結果的方法」
# 共用同一個方法命名空間。所以結果不要用跟動詞同名的 reader(例如 database),
# 而是統一用一個非動詞名的彙整方法 to_h —— config-writer 也點不到它。

require_relative "prism_dsl"

class AppConfig < PrismDSL::Space
  def initialize          # 自由寫,不必 super
    @values   = {}
    @plugins  = []
    @server   = nil
    @database = nil
  end

  # 結果出口:用非動詞名,避免和 dsl_method 撞名;也不是 dsl_method ⇒ 輸入點不到。
  def to_h
    h = @values.dup
    h[:server]   = @server      if @server
    h[:plugins]  = @plugins unless @plugins.empty?
    h[:database] = @database    if @database
    h
  end

  # ── 值方法(用在參數位置,回傳值)──
  dsl_method(:env)    { |name, fallback = nil| ENV.fetch(name.to_s, fallback) }
  dsl_method(:to_int) { |v| Integer(v) }
  dsl_method(:ref) do |key|
    @values.fetch(key) { raise ArgumentError, "ref(:#{key}) 找不到 —— 只能參照本層之前設過的 key" }
  end

  # ── 指令方法(改 self 的狀態)──
  dsl_method(:set) do |key, value|
    raise ArgumentError, "set 的 key 必須是符號,例如 set :port, 3000" unless key.is_a?(Symbol)
    @values[key] = value
  end

  dsl_method(:listen) do |host:, port:|
    @server = { host:, port: }
  end

  dsl_method(:plugin) do |name, **opts|
    raise ArgumentError, "plugin 名稱必須是符號" unless name.is_a?(Symbol)
    @plugins << { name:, **opts }
  end

  # ── 同詞彙巢狀(group):開一個自己的子空間,取它的 to_h 收進來 ──
  dsl_method(:group) do |name, &_|
    raise ArgumentError, "group 名稱必須是符號" unless name.is_a?(Symbol)
    @values[name] = subspace(self.class).to_h   # 隔離:子空間有自己的 @values
  end

  # ── 換詞彙巢狀(database):開一個 DatabaseConfig,並【顯式向下】注入 app_env ──
  dsl_method(:database) do |&_|
    @database = subspace(DatabaseConfig, app_env: @values[:env]).to_h
  end

  # ── 普通 helper:沒 dsl_method ⇒ 解析輸入永遠點不到(即使是 public)──
  def secret_helper
    File.read("/etc/passwd")
  end
end

# 另一套詞彙 = 另一個 class。它不知道自己被誰巢狀,看不到 AppConfig 的狀態;
# 要用外面的值,只能透過 initialize 宣告接受(這裡是 app_env)。
class DatabaseConfig < PrismDSL::Space
  def initialize(app_env: "dev")
    @app_env = app_env
    @opts    = {}
  end

  def to_h = { app_env: @app_env, **@opts }

  dsl_method(:adapter) { |name| @opts[:adapter] = name }
  dsl_method(:pool)    { |n| @opts[:pool] = Integer(n) }
end
