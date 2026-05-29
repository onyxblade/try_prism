require_relative "app_dsl"
require "pp"

def banner(title)
  puts
  puts "=" * 64
  puts title
  puts "=" * 64
end

LOADER = AppDSL.loader

banner "① 受控注入 — host 傳值,block 宣告參數名(block 仍不執行)"
app_name = "billing"   # 外層值,經由參數白名單送進去
config = LOADER.load_block(app_name, port: 8080, tier: :pro) do |name, port:, tier:|
  set :app,  name
  set :port, port
  set :tier, tier
  listen host: "127.0.0.1", port: port   # 參數也能餵給指令的關鍵字參數
  group :limits do
    set :rps, port                         # 巢狀區塊裡一樣看得到參數
  end
end
pp config

banner "② 可選參數的預設值(字面量)"
cfg2 = LOADER.load_block("api") do |name, workers: 4|
  set :app,     name
  set :workers, workers
end
pp cfg2

banner "③ 參數對不上 → 結構性錯誤,直接說清楚"
begin
  LOADER.load_block("x") do |name, port:|   # 少傳 port:
    set :app, name
  end
rescue PrismConfig::RejectedError => e
  puts "[已拒絕] #{e.message}"
end

banner "④ 沒宣告成參數的外層變數 → 仍被拒,並指路怎麼修"
secret = "可被外洩嗎?"
begin
  LOADER.load_block do
    set :x, secret   # secret 沒宣告成參數 → 拒絕
  end
rescue PrismConfig::RejectedError => e
  puts "[已拒絕] #{e.message}"
end
