require_relative "app_dsl"
require "pp"

def banner(title)
  puts
  puts "=" * 72
  puts title
  puts "=" * 72
end

banner "① 合法設定 —— 型別宣告全通過,連 port: ref(:port) 也走型別檢查"
config = AppConfig.parse do
  set :env,  "prod"
  set :root, "/srv/app"
  set :port, to_int(env("PORT", "8080"))
  listen host: "127.0.0.1", port: ref(:port)   # ref(:port) → 8080(Integer)→ 過 port: Integer
  plugin :auth, provider: "oauth"
  plugin :metrics
  group :limits do
    set :rps,   100
    set :burst, 250
  end
  database do
    adapter "postgres"
    pool 8
  end
end
pp config.to_h

banner "② 字面量型別不符 —— 一次彙整(同一句的多個型別問題也一起報)"
begin
  AppConfig.parse do
    set 123, "key 不是符號"          # key: Symbol → 收到 Integer
    listen host: 80, port: "8080"    # host 要 String、port 要 Integer:同一句兩個都錯
    plugin "metrics"                 # name: Symbol → 收到 String
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end

banner "③ ref / 值方法【算出來的值】也檢查 —— 錯誤指到使用點(不需靜態推導 ref 型別)"
begin
  AppConfig.parse do
    set :p, "8080"                    # 先存了個字串
    listen host: "h", port: ref(:p)   # ref(:p) → \"8080\"(String)→ port: Integer 不符,報在這行
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end

banner "④ 安全不變 —— 加了型別檢查,區塊仍然【沒被執行】"
$side_effect = "未被觸碰"
begin
  AppConfig.parse do
    secret = File.read("/etc/passwd")            # 賦值 + 帶 receiver 的呼叫
    set :evil, system("touch /tmp/PWNED_stage10") # 未宣告方法 system
    plugin :p, token: `id`                       # 反引號 XString
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end
puts
puts "→ $side_effect 仍是:#{$side_effect.inspect}"
puts "→ /tmp/PWNED_stage10 存在嗎?#{File.exist?('/tmp/PWNED_stage10')}"

banner "⑤ type_check 跟 dsl_method 分開,且宣告期就驗參數名 —— 作者寫錯當場罵"
begin
  Class.new(PrismDSL::Space) do
    dsl_method(:foo) { |a| a }
    type_check(:foo, b: Integer)     # foo 沒有 b 這個參數
  end
rescue ArgumentError => e
  puts "[定義期被擋] #{e.message}"
end
