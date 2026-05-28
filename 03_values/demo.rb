require_relative "prism_config"
require "pp"

def banner(title)
  puts
  puts "=" * 64
  puts title
  puts "=" * 64
end

here = __dir__

banner "① 含陣列/雜湊的設定 examples/server.conf"
good = File.read(File.join(here, "examples", "server.conf"))
pp PrismConfig::SafeLoader.load(good, filename: "server.conf")

banner "② 任意呼叫藏在陣列元素裡 examples/attack.conf"
puts "值可巢狀後多了藏程式碼的地方;遞迴的 literal 仍會在該元素那格拒絕:"
attack = File.read(File.join(here, "examples", "attack.conf"))
begin
  PrismConfig::SafeLoader.load(attack, filename: "attack.conf")
rescue PrismConfig::RejectedError => e
  puts
  puts "[已安全拒絕]"
  puts e.message
end
