# host 端:用引擎宣告「這套 config DSL 有哪些詞彙」。
#
# 這是【可信】的 Ruby —— 由應用作者撰寫,不是來自不可信的 .conf。
# 三者刻意分成三個檔案,凸顯責任邊界:
#   prism_config.rb  通用安全引擎(誰都不用改)
#   app_dsl.rb       host 暴露的接口(本檔,應用自訂、可信)
#   examples/*.conf  不可信輸入(只能用上面宣告的詞彙)

require_relative "prism_config"

module AppDSL
  def self.loader
    PrismConfig::SafeLoader.define do |dsl|
      # ── 值函數:回傳值,給參數用。預設純取值(handler 不拿 ctx)。 ──────
      # host 自己決定「能取什麼」—— 這裡只開放讀環境變數,而非任意系統呼叫。
      dsl.function(:env) do |name, fallback = nil|
        ENV.fetch(name.to_s, fallback)
      end

      dsl.function(:to_int) do |value|
        Integer(value)
      end

      dsl.function(:path_join) do |*parts|
        File.join(*parts.map(&:to_s))
      end

      # ── 指令:語句層,有副作用 / 建構結構。handler 第一參數是 ctx。 ──────
      dsl.command(:listen) do |ctx, host:, port:|
        ctx.set(:server, { host: host, port: port })
      end

      dsl.command(:plugin) do |ctx, name, **opts|
        raise ArgumentError, "plugin 名稱必須是符號" unless name.is_a?(Symbol)
        list = ctx[:plugins] || []
        ctx.set(:plugins, list + [{ name: name, **opts }])
      end
    end
  end
end
