require_relative "prism_config"
require "pp"

def banner(title)
  puts
  puts "=" * 64
  puts title
  puts "=" * 64
end

here = __dir__

def load_file(name)
  PrismConfig::SafeLoader.load(File.read(File.join(__dir__, "examples", name)), filename: name)
end

banner "① 值之間用 ref(:key) 參照 examples/server.conf"
pp load_file("server.conf")

banner "② 想藉 ref 的口呼叫別的東西 examples/attack.conf"
puts "值裡只認 ref;File.read 這種帶 receiver 的呼叫被拒絕:"
begin
  load_file("attack.conf")
rescue PrismConfig::RejectedError => e
  puts "\n[已安全拒絕]\n#{e.message}"
end

banner "③ 參照未設定的 key examples/bad_ref.conf"
puts "只能向後參照;找不到時友善報錯而非 crash:"
begin
  load_file("bad_ref.conf")
rescue PrismConfig::RejectedError => e
  puts "\n[已拒絕]\n#{e.message}"
end
