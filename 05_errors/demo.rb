require_relative "prism_config"
require "pp"

def banner(title)
  puts
  puts "=" * 64
  puts title
  puts "=" * 64
end

def load_file(name)
  PrismConfig::SafeLoader.load(File.read(File.join(__dir__, "examples", name)), filename: name)
end

banner "① 合法設定 examples/server.conf — 仍正常載入"
pp load_file("server.conf")

banner "② 多處違規 examples/many_errors.conf — 一次回報全部"
puts "以前遇第一個錯就停;現在收集完整棵樹再一起報。"
puts "而且 system / File.read 全程沒被執行(只是被解析、被收集成訊息):"
begin
  load_file("many_errors.conf")
rescue PrismConfig::RejectedError => e
  puts "\n[已拒絕]\n#{e.message}"
end
