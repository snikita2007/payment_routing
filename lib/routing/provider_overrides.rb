require "yaml"

require_relative "errors"
require_relative "provider"

module Routing
  # Поля, которых нет в providers.json, — volume_share_pct, daily_turnover_min/max,
  # requests_per_minute_limit и прочее, что ТЗ предлагает командам задать самим.
  #
  # Держим их отдельным файлом, а не правкой data/providers.json: на сдаче организаторы
  # пришлют свой providers.json, и правки в данных пропадут вместе с ним.
  #
  # Приоритет, от высшего к низшему:
  #   overrides[имя] > overrides[all] > данные из providers.json > defaults[имя] > defaults[all]
  #
  # То есть defaults только дополняют пробел, а overrides перебивают данные.
  # Явный null в данных считается пробелом: у spacepayments все лимиты записаны как null,
  # и Provider читает их точно так же, как отсутствующие.
  class ProviderOverrides
    DEFAULT_PATH = File.expand_path("../../config/provider_overrides.yml", __dir__).freeze
    ALL = "all".freeze

    # providers — готовые Provider, filled — что и кому мы дозаполнили сами.
    # filled уходит в отчёт: видно, где цифра из данных, а где наша.
    Applied = Struct.new(:providers, :filled, keyword_init: true)

    attr_reader :defaults, :overrides

    def self.load(path = DEFAULT_PATH)
      new(read_file(path))
    end

    def self.empty
      new({})
    end

    def self.read_file(path)
      return {} if path.nil? || !File.file?(path)

      parsed = YAML.safe_load_file(path, permitted_classes: [], aliases: true)
      return {} if parsed.nil?

      unless parsed.is_a?(Hash)
        raise InvalidInputError, "#{path}: ожидался объект с настройками, получено #{parsed.class}"
      end

      parsed
    rescue Psych::Exception => e
      raise InvalidInputError, "#{path}: не разбирается как YAML — #{e.message}"
    end

    def initialize(raw = {})
      @defaults = section(raw, "defaults")
      @overrides = section(raw, "overrides")
    end

    def apply(providers)
      filled = {}

      patched = Array(providers).map do |provider|
        merged, added = merge_for(provider)
        filled[provider.name] = added unless added.empty?
        added.empty? && overrides_for(provider.name).empty? ? provider : Provider.from_hash(merged)
      end

      Applied.new(providers: patched, filled: filled)
    end

    private

    def merge_for(provider)
      merged = provider.raw.dup
      added = []

      defaults_for(provider.name).each do |key, value|
        next unless merged[key].nil? && merged[key.to_sym].nil?

        merged[key] = value
        added << key
      end

      overrides_for(provider.name).each { |key, value| merged[key] = value }

      [merged, added]
    end

    def defaults_for(name)
      (defaults[ALL] || {}).merge(defaults[name] || {})
    end

    def overrides_for(name)
      (overrides[ALL] || {}).merge(overrides[name] || {})
    end

    def section(raw, key)
      value = raw[key] || raw[key.to_sym]
      return {} unless value.is_a?(Hash)

      value.to_h do |name, fields|
        [name.to_s, fields.is_a?(Hash) ? fields.to_h { |k, v| [k.to_s, v] } : {}]
      end
    end
  end
end
