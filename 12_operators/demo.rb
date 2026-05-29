require_relative "app_dsl"
require "pp"

def banner(title)
  puts
  puts "=" * 72
  puts title
  puts "=" * 72
end

banner "① 數值運算能用了 —— 而且是 host 宣告的 + - *(引擎不做算術)"
config = AppConfig.parse do
  set :base,    8000
  set :workers, to_int(env("WORKERS", "4"))
  set :max_conn, ref(:workers) * 64           # host 的 *(數值)
  set :window,   ref(:base) - 100             # -
  set :grid,    (ref(:workers) + 1) * 8       # 巢狀運算
  listen host: "127.0.0.1", port: ref(:base) + 80   # 運算結果(Integer)→ 走 type_check 過關
  set :banner, "ready: #{ref(:workers) * 64} conns"  # 運算嵌在插值裡(跨 Stage 11)
end
pp config.to_h

banner "② host 沒宣告的運算 —— 引擎直接擋(host 決定「不開放」/ 與 **)"
begin
  AppConfig.parse do
    set :a, 10 / 2      # host 沒宣告 :/  → 不開放
    set :b, 2 ** 16     # host 沒宣告 :** → 不開放(指數炸彈)
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end

banner "③ host 的 * 政策擋記憶體炸彈 —— 非數值相乘被 host 的 body 拒(乘法根本沒發生)"
begin
  AppConfig.parse do
    set :bomb1, "x" * 1000000000   # String * Int → host 的型別閘擋下
    set :bomb2, [0] * 1000000000   # Array  * Int → 同上
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end

banner "④ 運算元一樣繼承全套安全 —— 危險的運算元在求值時就被擋"
$side_effect = "未被觸碰"
begin
  AppConfig.parse do
    set :a, File.read("/etc/passwd") + "!"   # 運算元帶 receiver → 被擋
    set :b, secret_helper * 2                # 運算元是未宣告方法 → 被擋
    set :c, $side_effect + "x"               # 運算元是全域變數 → 被擋
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end
puts
puts "→ $side_effect 仍是:#{$side_effect.inspect}"

banner "⑤ 引擎層的底 + 作者期驗證 —— operator 只能宣告真正的中綴符號"
begin
  Class.new(PrismDSL::Space) do
    operator(:read) { |a, b| a }     # :read 不是運算子符號(否則就替 File.read 開了門)
  end
rescue ArgumentError => e
  puts "[定義期被擋] #{e.message}"
end
begin
  Class.new(PrismDSL::Space) do
    operator(:+) { |a| a }           # body arity 不是 2
  end
rescue ArgumentError => e
  puts "[定義期被擋] #{e.message}"
end
