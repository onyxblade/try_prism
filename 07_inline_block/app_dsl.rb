# host 端接口(沿用 Stage 6):用引擎宣告這套 DSL 的詞彙。
# 這是【可信】的 Ruby;不可信的是稍後 load_block 裡那段被解析的內容。

require_relative "prism_config"

module AppDSL
  def self.loader
    PrismConfig::SafeLoader.define do |dsl|
      dsl.function(:env) do |name, fallback = nil|
        ENV.fetch(name.to_s, fallback)
      end

      dsl.function(:to_int) do |value|
        Integer(value)
      end

      dsl.function(:path_join) do |*parts|
        File.join(*parts.map(&:to_s))
      end

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
