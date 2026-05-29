require_relative "app_dsl"
require "pp"

def banner(title)
  puts
  puts "=" * 72
  puts title
  puts "=" * 72
end

# 注意:下面的 DSL 來源是【字串】(用 <<~'CONF' 不插值的 heredoc,所以 #{...} 原樣
# 留在字串裡,交給 Prism 解析,而不是被這支 demo.rb 的 Ruby 先展開)。

banner "① 直接載入不可信字串 —— 靠 env / secret / ref 調方法跟 host 溝通"
src = <<~'CONF'
  set :env,     env("RACK_ENV", "dev")
  set :db_host, secret(:db_host)
  set :db_url,  "postgres://#{secret(:db_host)}:#{secret(:db_port)}/app"
  set :workers, to_int(env("WORKERS", "4"))
  set :max,     ref(:workers) * 64
CONF
config = AppConfig.parse_string(src, secrets: { db_host: "10.0.0.5", db_port: 5432 })
pp config.to_h

banner "② 同一條入口載入【攻擊字串】—— 全程只解析、從不執行"
$side_effect = "未被觸碰"
attack = <<~'CONF'
  set :a, File.read("/etc/passwd")   # value 位:receiver 是常數 File → 求值就死
  system("rm -rf /")                 # statement 位:未宣告指令 → 拒
  set :b, secret_helper              # value 位:未宣告方法 → 拒
  $side_effect = "PWNED"             # 賦值 → 拒(而且字串只被解析,賦值從不執行)
CONF
begin
  AppConfig.parse_string(attack, secrets: {})
rescue PrismDSL::RejectedError => e
  puts e.message
end
puts
puts "→ $side_effect 仍是:#{$side_effect.inspect}"

banner "③ host 方法 raise(secret 不存在)→ 友善彙整報錯"
begin
  AppConfig.parse_string('set :x, secret(:nope)', secrets: { db_host: "x" })
rescue PrismDSL::RejectedError => e
  puts e.message
end

banner "④ DSL 看不到綁定 —— secrets 不是可讀的名字,只能調 secret(:k)"
begin
  AppConfig.parse_string('set :leak, secrets', secrets: { db_host: "x" })
rescue PrismDSL::RejectedError => e
  puts e.message
end

banner "⑤ 兩條入口共用同一套 interpreter —— inline block(可信嵌入)仍可用"
inline = AppConfig.parse(secrets: { db_host: "9.9.9.9" }) do
  set :host, secret(:db_host)
  set :loud, "ok".upcase           # stub 點方法,跟字串入口一視同仁
end
pp inline.to_h
