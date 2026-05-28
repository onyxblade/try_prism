require_relative "prism_config"

def banner(title)
  puts
  puts "=" * 64
  puts title
  puts "=" * 64
end

here = __dir__

banner "① 正常設定 examples/server.conf — 解析成 Ruby Hash"
good = File.read(File.join(here, "examples", "server.conf"))
p PrismConfig::SafeLoader.load(good, filename: "server.conf")

banner "② 惡意設定 examples/attack.conf — 含 system(...)"
puts "若這行被『執行』,stdout 會出現:>>> 任意指令被執行了 <<<"
puts "Prism 版只『解析』不執行,所以 system 從未運行,而是被拒絕:"
attack = File.read(File.join(here, "examples", "attack.conf"))
begin
  PrismConfig::SafeLoader.load(attack, filename: "attack.conf")
rescue PrismConfig::RejectedError => e
  puts
  puts "[已安全拒絕]"
  puts e.message
end
