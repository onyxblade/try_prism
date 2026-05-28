require_relative "app_dsl"
require "pp"

def banner(title)
  puts
  puts "=" * 64
  puts title
  puts "=" * 64
end

LOADER = AppDSL.loader

def load_file(name)
  LOADER.load(File.read(File.join(__dir__, "examples", name)), filename: name)
end

banner "① 合法設定 examples/app.conf — host 接口正常運作"
puts "set/group/ref 是內建;env/to_int/path_join/listen/plugin 由 host 註冊。"
pp load_file("app.conf")

banner "② examples/attack.conf — 未註冊的名字/形狀全被拒,一次回報"
puts "唯一會執行的 Ruby 是 host 自己的 handler;system / File.read / 反引號"
puts "都不在註冊表,連求值都不會 —— 沒有任何一行被執行:"
begin
  load_file("attack.conf")
rescue PrismConfig::RejectedError => e
  puts "\n[已拒絕]\n#{e.message}"
end
