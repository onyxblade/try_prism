require_relative "app_dsl"
require "pp"

def banner(title)
  puts
  puts "=" * 72
  puts title
  puts "=" * 72
end

banner "① 插值終於能用了 —— Stage 9/10 寫不出來的「拼字串」"
config = AppConfig.parse do
  set :scheme, "redis"
  set :host,   env("REDIS_HOST", "127.0.0.1")
  set :port,   to_int(env("REDIS_PORT", "6379"))
  # 字面量 + ref + 巢狀值方法,全部混在一條插值裡:
  set :url,    "#{ref(:scheme)}://#{ref(:host)}:#{ref(:port)}/0"
  set :banner, "listening on #{ref(:host)} (env=#{env("RACK_ENV", "dev")})"
  # 插值結果是 String,丟進 host: String 剛好:
  listen host: "#{ref(:host)}", port: ref(:port)
end
pp config.to_h

banner "② 插值不是後門 —— \#{} 裡每一段都走回 eval_value 的全套防線"
$side_effect = "未被觸碰"
begin
  AppConfig.parse do
    set :a, "leak=#{File.read("/etc/passwd")}"   # 帶 receiver → 被既有的牆擋
    set :b, "who=#{secret_helper}"               # 未宣告方法 → 被白名單擋
    set :c, "x=#{$side_effect}"                  # 外層/全域變數 → 被既有規則擋
    set :d, "v=#{`id`}"                          # 反引號 → 不支援的值
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end
puts
puts "→ $side_effect 仍是:#{$side_effect.inspect}"

banner "③ \#@ivar 這種「無花括號變數插值」也明確擋掉"
begin
  AppConfig.parse do
    set :leak, "secret is #@values"   # EmbeddedVariableNode:會去讀 space 的 ivar
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end

banner "④ 與 type_check 呼應 —— 插值結果【必為 String】,丟進 port: Integer 被擋在使用點"
begin
  AppConfig.parse do
    set :p, 8080
    listen host: "h", port: "#{ref(:p)}"   # ref(:p)=8080,但插值把它變字串 → port: Integer 不符
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end
