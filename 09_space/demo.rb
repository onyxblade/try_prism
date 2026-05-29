require_relative "app_dsl"
require "pp"

def banner(title)
  puts
  puts "=" * 68
  puts title
  puts "=" * 68
end

banner "① DSL 就是一個 class — AppConfig.parse do … end 解析(非執行)後回傳實例"
config = AppConfig.parse do
  set :env,  "prod"
  set :root, "/srv/app"
  set :port, to_int(env("PORT", "8080"))   # 值方法巢狀:env → to_int
  listen host: "127.0.0.1", port: ref(:port)
  plugin :auth, provider: "oauth"
  plugin :metrics
  group :limits do                          # 同詞彙巢狀(subspace(self.class))
    set :rps,   100
    set :burst, 250
  end
  database do                               # 換詞彙巢狀 + 顯式向下注入 app_env
    adapter "postgres"
    pool 8
  end
end
pp config.to_h

banner "② 證明區塊【沒被執行】— File.read / system / 反引號 / 賦值 全沒發生"
$side_effect = "未被觸碰"
begin
  AppConfig.parse do
    secret = File.read("/etc/passwd")          # 賦值 + 帶 receiver 的呼叫
    set :leak, secret                          # 引用外層區域變數
    set :evil, system("touch /tmp/PWNED_stage9") # 未宣告方法 system
    plugin :p, token: `id`                     # 反引號 XString
    $danger = "executed"                       # 全域賦值
    danger_zone                                # 未知指令
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end
puts
puts "→ $side_effect 仍是:#{$side_effect.inspect}"
puts "→ /tmp/PWNED_stage9 存在嗎?#{File.exist?('/tmp/PWNED_stage9')}"

banner "③ 明確白名單:類別上真有 secret_helper 方法,但沒 dsl_method ⇒ 點不到"
puts "AppConfig 實例真的有這個方法嗎?#{AppConfig.new.respond_to?(:secret_helper)}"
begin
  AppConfig.parse do
    secret_helper      # 是真方法(public),但不在 dsl_method 白名單
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end

banner "④ 子空間隔離 — database 裡看不到外層的 set,要靠 initialize 注入"
puts "app_env 是 AppConfig 顯式傳下去的;DatabaseConfig 自己看不到 @values。"
cfg = AppConfig.parse do
  set :env, "staging"
  database do
    adapter "mysql"
    pool 4
  end
end
pp cfg.to_h         # database => {app_env: "staging", adapter: "mysql", pool: 4}
