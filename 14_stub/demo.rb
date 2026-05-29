require_relative "app_dsl"
require "pp"

def banner(title)
  puts
  puts "=" * 72
  puts title
  puts "=" * 72
end

banner "① 帶 receiver 的呼叫按型別 stub 分派 —— ancestry(Numeric 覆蓋 Int/Float)＋鏈式"
config = AppConfig.parse do
  set :base,    8000
  set :workers, 4
  set :max,     ref(:workers) * 64        # Integer → 命中 Numeric stub 的 *
  set :window,  ref(:base) - 100          # Numeric -
  set :grid,    (ref(:workers) + 1) * 8   # 巢狀:+ 再 *
  set :ratio,   3.5 * 2                    # Float → 同一個 Numeric stub
  set :host,    "redis-01"
  set :HOST,    ref(:host).upcase          # String 的點方法
  set :namelen, ref(:host).length          # String 的點方法
  set :chain,   "core".upcase.length       # 鏈式:String→String→Integer,每跳各自查 stub
end
pp config.to_h

banner "② Stage 12 的 hack 沒了 —— 記憶體炸彈靠「型別沒宣告該方法」結構性被拒"
begin
  AppConfig.parse do
    set :bomb1, "x" * 1000000000   # String stub 沒宣告 * → 拒(乘法根本沒發生)
    set :bomb2, [0] * 1000000000   # Array 根本沒有 stub → 拒
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end

banner "③ 未宣告的方法 = 拒絕,鏈式中途那一跳也 fail-closed"
begin
  AppConfig.parse do
    set :base, "redis"
    set :a, 2 ** 16                    # Integer 經 Numeric,但沒宣告 ** → 拒
    set :b, ref(:base).downcase        # String 沒宣告 downcase → 拒
    set :c, ref(:base).upcase.reverse  # upcase 通過,reverse 沒宣告 → 中途被拒
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end

banner "④ 還是不是後門 —— receiver 求不出來 / 型別沒這方法,危險呼叫一律死"
$side_effect = "未被觸碰"
begin
  AppConfig.parse do
    set :base, "redis"
    set :a, File.read("/etc/passwd")        # receiver 是常數 File → 求值就死
    set :b, ref(:base).system("rm -rf /")   # String stub 沒 system → 拒(arg 根本沒求值)
    set :c, secret_helper.upcase            # receiver 是未宣告方法 → 求值就死(File.read 沒跑)
    set :d, $side_effect.length             # receiver 是全域變數 → 求值就死
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end
puts
puts "→ $side_effect 仍是:#{$side_effect.inspect}"

banner "⑤ 作者期驗證 —— stub 不可掛太廣的根、op 至少要收 receiver、型別須是 Module"
begin
  Class.new(PrismDSL::Space) do
    stub(Object) { op(:+) { |a, b| a } }   # Object 太廣 → 等於替所有值開門
  end
rescue ArgumentError => e
  puts "[定義期被擋] #{e.message}"
end
begin
  Class.new(PrismDSL::Space) do
    stub(Integer) { op(:+) { } }           # body arity 0,連 receiver 都收不到
  end
rescue ArgumentError => e
  puts "[定義期被擋] #{e.message}"
end
begin
  Class.new(PrismDSL::Space) do
    stub("Integer") { op(:+) { |a, b| a } }  # "Integer" 是字串,不是 Class/Module
  end
rescue ArgumentError => e
  puts "[定義期被擋] #{e.message}"
end
