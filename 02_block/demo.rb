require_relative "prism_config"
require "pp"

def banner(title)
  puts
  puts "=" * 64
  puts title
  puts "=" * 64
end

here = __dir__

banner "① 巢狀設定 examples/server.conf — 解析成巢狀 Hash"
good = File.read(File.join(here, "examples", "server.conf"))
pp PrismConfig::SafeLoader.load(good, filename: "server.conf")

banner "② 惡意行藏在 group 裡 examples/attack.conf"
puts "Prism 版只解析不執行;深層的 system 一樣被拒絕,位置精準到該行:"
attack = File.read(File.join(here, "examples", "attack.conf"))
begin
  PrismConfig::SafeLoader.load(attack, filename: "attack.conf")
rescue PrismConfig::RejectedError => e
  puts
  puts "[已安全拒絕]"
  puts e.message
end
