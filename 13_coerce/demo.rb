require_relative "app_dsl"
require "pp"

def banner(title)
  puts
  puts "=" * 72
  puts title
  puts "=" * 72
end

banner "① 統一生效 —— string 與 symbol 可互換,且【統一折成 symbol】"
config = AppConfig.parse do
  set "base", 8000           # 字串 key → host 折成 :base
  set :workers, 4            # 符號 key 照舊
  set "max", ref("base")     # 用字串 ref,照樣找到 :base(ref 的 key 也折了)
  plugin "cache", ttl: 60    # plugin name 字串 → :cache
  group "db" do              # group name 字串 → :db
    set :pool, 5
  end
end
pp config.to_h
puts "→ 全部 key 都是 symbol?#{config.to_h.keys.all? { |k| k.is_a?(Symbol) }}"

banner "② 兩種寫法產生【完全相同】的結果 —— 這才叫「統一」"
a = AppConfig.parse do
  set :env, "prod"
  plugin :metrics
end
b = AppConfig.parse do
  set "env", "prod"          # 字串 key
  plugin "metrics"           # 字串 name
end
puts "a = #{a.to_h.inspect}"
puts "b = #{b.to_h.inspect}"
puts "→ a.to_h == b.to_h ?  #{a.to_h == b.to_h}"

banner "③ host 決定哪裡【不】統一 —— listen 沒掛 coerce,:localhost 仍被 host: String 擋"
begin
  AppConfig.parse do
    listen host: :localhost, port: 8080   # Symbol 不被當成 String(這個參數 host 沒宣告 coerce)
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end

banner "④ 正規化不是後門 —— coercer 只拿到已求值的 inert 值;危險的 key 在求值期就被擋"
$side_effect = "未被觸碰"
begin
  AppConfig.parse do
    set File.read("/etc/passwd"), 1   # key 帶 receiver → eval_value 階段就被擋,到不了 coercer
    set secret_helper, 2              # key 是未宣告方法 → 被白名單擋
    set `id`, 3                       # key 是反引號指令 → 不支援的值
  end
rescue PrismDSL::RejectedError => e
  puts e.message
end
puts
puts "→ $side_effect 仍是:#{$side_effect.inspect}"

banner "⑤ 作者期驗證 —— coerce 跟 type_check 同一套:只能掛在已宣告方法的真參數上"
begin
  Class.new(PrismDSL::Space) do
    def initialize; end
    dsl_method(:set) { |key, value| }
    coerce(:nope, key: ->(v) { v })       # 方法沒宣告
  end
rescue ArgumentError => e
  puts "[定義期被擋] #{e.message}"
end
begin
  Class.new(PrismDSL::Space) do
    def initialize; end
    dsl_method(:set) { |key, value| }
    coerce(:set, bogus: ->(v) { v })      # set 沒有 bogus 這個參數
  end
rescue ArgumentError => e
  puts "[定義期被擋] #{e.message}"
end
begin
  Class.new(PrismDSL::Space) do
    def initialize; end
    dsl_method(:set) { |key, value| }
    coerce(:set, key: "不是可呼叫物")        # coercer 必須是收單一值的可呼叫物
  end
rescue ArgumentError => e
  puts "[定義期被擋] #{e.message}"
end
