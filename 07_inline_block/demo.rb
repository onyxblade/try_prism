require_relative "app_dsl"
require "pp"

def banner(title)
  puts
  puts "=" * 64
  puts title
  puts "=" * 64
end

LOADER = AppDSL.loader

banner "① inline 區塊 — 看起來是普通 Ruby block,實際走 Prism 解析"
puts "block 從不被 call;引擎用 source_location 找到它、解析成 AST 再走訪。"
config = LOADER.load_block do
  set :root, "/srv/app"
  set :name, env("APP_NAME", "app")
  set :port, to_int(env("PORT", "8080"))
  listen host: "127.0.0.1", port: ref(:port)
  group :limits do
    set :rps,   100
    set :burst, ref(:rps)
  end
  plugin :auth, provider: "oauth"
end
pp config

banner "② 證明區塊【沒被執行】— system / File.read / 賦值 全都沒發生"
$side_effect = "未被觸碰"
puts "下面這個 block 裡塞了 File.read、system、全域賦值。若它被執行,"
puts "$side_effect 會變、/tmp/PWNED 會出現。看結果:"
begin
  LOADER.load_block do
    secret = File.read("/etc/passwd")     # 若執行 → 真的讀檔
    set :leak, secret
    set :evil, system("touch /tmp/PWNED") # 若執行 → 真的建檔
    $side_effect = "被執行了!"            # 若執行 → 全域變數會變
  end
rescue PrismConfig::RejectedError => e
  puts "\n[已拒絕]\n#{e.message}"
end
puts
puts "→ $side_effect 仍是:#{$side_effect.inspect}"
puts "→ /tmp/PWNED 存在嗎?#{File.exist?('/tmp/PWNED')}"

banner "③ 為什麼不能順手用外層變數 — 因為這個 block 根本沒執行"
port = 9999
puts "外面有 port = 9999,但 block 是被解析的,拿不到它的執行期值:"
begin
  LOADER.load_block do
    set :port, port   # port 是外層區域變數 → 解析成 LocalVariableRead
  end
rescue PrismConfig::RejectedError => e
  puts "\n[已拒絕]\n#{e.message}"
end
