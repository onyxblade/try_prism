# host 端(可信代碼):一套 DSL 就是一個 PrismDSL::Space 子類。
#
# Stage 15 重點:用 parse_string 載入【不可信字串】,host↔DSL 純用方法溝通。
#   - 不可信字串靠【調方法】跟 host 要東西:env(拉環境變數)、secret(拉 per-load
#     機密)、ref(拉本層設過的值)。DSL 永遠看不到「綁定」,只看得到這些方法。
#   - per-load 的可信 context(secrets)在 Ruby 側 push 進 initialize,再由 secret
#     這個 dsl_method 暴露。host 呼叫:AppConfig.parse_string(src, secrets: {...})。
#   - 想注入新的 per-load 值,就多寫一個讀 ivar 的 dsl_method,不必改引擎。
#
# (沿用前面:dsl_method 管暴露面/安全,type_check 管型別,coerce 管正規化(統一
#  string/symbol),stub 管帶 receiver 的方法(按型別),插值/括號已開。)

require_relative "prism_dsl"

class AppConfig < PrismDSL::Space
  # secrets:per-load 的可信 context,從 parse_string/parse 經 initialize 注入。
  # 預設 {} 讓無注入的呼叫(含 group 的 subspace(self.class))照樣能建。
  def initialize(secrets: {})   # 自由寫,不必 super
    @values   = {}
    @plugins  = []
    @server   = nil
    @database = nil
    @secrets  = secrets
  end

  # 結果出口:非動詞名,避免和 dsl_method 撞名;也不是 dsl_method ⇒ 輸入點不到。
  def to_h
    h = @values.dup
    h[:server]   = @server      if @server
    h[:plugins]  = @plugins unless @plugins.empty?
    h[:database] = @database    if @database
    h
  end

  # host 的政策:把 String 當成 Symbol 的同義詞,統一折成 Symbol(非 String 原樣)。
  # 一個 lambda 共用給多個參數;想改方向(折成 string)只要改這裡,引擎不介入。
  SYMBOLIZE = ->(v) { v.is_a?(String) ? v.to_sym : v }

  # ── 值方法(用在參數位置,回傳值)──
  dsl_method(:env) { |name, fallback = nil| ENV.fetch(name.to_s, fallback) }
  type_check(:env, name: [String, Symbol], fallback: String)   # fallback 省略時不檢查
  # env 不掛 coerce:它本來就吃 String/Symbol,body 自己 to_s,沒有統一的需要。

  dsl_method(:to_int) { |v| Integer(v) }          # 不宣告型別:靠 Integer() 自行強轉(opt-in 的反例)

  dsl_method(:ref) do |key|
    @values.fetch(key) { raise ArgumentError, "ref(:#{key}) 找不到 —— 只能參照本層之前設過的 key" }
  end
  type_check(:ref, key: Symbol)
  coerce(:ref, key: SYMBOLIZE)   # ref("base") 與 ref(:base) 都折成 :base → 對得上 set 存的 key

  # secret:把 per-load 注入的機密【以方法暴露】給不可信字串。DSL 只能調 secret(:k),
  # 永遠拿不到 @secrets 這個綁定本身 —— 這就是「方法式溝通」取代「注入成綁定」。
  dsl_method(:secret) do |name|
    @secrets.fetch(name) { raise "找不到 secret :#{name}(host 沒在這次載入提供)" }
  end
  type_check(:secret, name: Symbol)
  coerce(:secret, name: SYMBOLIZE)   # secret("db_host") 與 secret(:db_host) 一致

  # ── 型別 stub(host 決定每個型別有哪些方法、各自怎麼算)──
  # body 第一個參數是 receiver,其餘是引數(`a + b` → recv=a, args=[b])。
  stub Numeric do          # Integer / Float 都沿 ancestors 命中這裡
    op(:+) { |a, b| a + b }
    op(:-) { |a, b| a - b }
    op(:*) { |a, b| a * b }   # 不必再 `unless Numeric`:String 走不到這(它不是 Numeric)
    # 故意【不宣告】:/ 與 **  —— host 決定不開放(除零、指數計算炸彈)
  end

  stub String do
    op(:+)      { |a, b| a + b }   # 串接
    op(:upcase) { |s| s.upcase }   # 點方法(只收 receiver)
    op(:length) { |s| s.length }
    # 故意【不宣告】:*  —— "x" * 10**9 結構性被拒(不靠 runtime 型別閘)
    # 故意【不宣告】:% 、<< … —— 格式字串 / 就地改值都不開放
  end
  # 沒有 stub Array / Hash …:那些型別的值上任何方法都不能呼叫(fail-closed)。

  # ── 指令方法(改 self 的狀態)──
  dsl_method(:set) { |key, value| @values[key] = value }   # 原本的 key.is_a?(Symbol) 檢查 → 移到 type_check
  type_check(:set, key: Symbol)                            # value 不限:set 收任意設定值
  coerce(:set, key: SYMBOLIZE)                             # set "base", 1 → key 折成 :base 再過 type_check

  dsl_method(:listen) { |host:, port:| @server = { host:, port: } }
  type_check(:listen, host: String, port: Integer)         # port: ref(:port) 也走這條 —— 查算出來的值
  # listen 不掛 coerce:host 決定這裡【不】統一,:localhost(Symbol)仍會被 host: String 擋。

  dsl_method(:plugin) { |name, **opts| @plugins << { name:, **opts } }
  type_check(:plugin, name: Symbol)
  coerce(:plugin, name: SYMBOLIZE)   # plugin "cache" 與 plugin :cache 一致

  # ── 同詞彙巢狀(group):開一個自己的子空間,取它的 to_h 收進來 ──
  dsl_method(:group) do |name, &_|
    @values[name] = subspace(self.class).to_h   # 隔離:子空間有自己的 @values
  end
  type_check(:group, name: Symbol)
  coerce(:group, name: SYMBOLIZE)    # group "db" 與 group :db 一致

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
