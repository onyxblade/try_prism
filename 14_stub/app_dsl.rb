# host 端(可信代碼):一套 DSL 就是一個 PrismDSL::Space 子類。
#
# Stage 14 重點:帶 receiver 的呼叫(`a + b`、`s.upcase`)改成【按型別 stub 分派】。
# 看下面的 stub 宣告 —— host 為每個型別決定「這個型別的值上有哪些方法、各自怎麼算」:
#   - stub Numeric:+ - *  →  Integer/Float 都吃(沿 ancestors 命中 Numeric)
#   - stub String :+(串接)/ upcase / length;【故意不宣告 *】→ "x"*big 結構性被拒
#   - 沒宣告 stub 的型別(Array…)→ 任何方法都不能呼叫
# 對比 Stage 12:以前 operator(:*) 的 body 要寫 `unless Numeric` 來決定「哪些型別
# 能用 *」(把「哪些型別」混進「怎麼算」);現在「哪些型別」=「哪些 stub 宣告了 *」,
# body 只管「怎麼算」—— 記憶體炸彈靠「String 沒宣告 *」結構性擋,不靠 runtime 檢查。
#
# (沿用前面:dsl_method 管暴露面/安全(無 receiver 的指令/值方法),type_check 管
#  值型別/正確性,coerce 管正規化(統一 string/symbol),插值/括號已開;
#  to_int/pool 靠 Integer() 強轉。)

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
