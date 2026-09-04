require_relative "errors"

module Routing
  # Провайдер из providers.json. Все поля читаются через методы с дефолтами:
  # часть полей (priority, requests_per_minute_limit, daily_turnover_*, volume_share_pct)
  # команда задаёт сама, и на непропатченном providers.json их просто нет.
  #
  # Изменяемые счётчики (оборот, in-progress) здесь только как НАЧАЛЬНОЕ значение —
  # по ходу очереди их держит RoutingState.
  class Provider
    UNLIMITED = Float::INFINITY

    attr_reader :name, :raw

    def self.from_hash(hash)
      raise InvalidInputError, "провайдер задан не объектом: #{hash.inspect}" unless hash.is_a?(Hash)

      name = fetch_any(hash, "name", "provider", "id", "code")
      raise InvalidInputError, "у провайдера нет имени: #{hash.inspect}" if name.to_s.strip.empty?

      provider = new(name.to_s, hash)
      provider.validate!
      provider
    end

    def self.fetch_any(hash, *keys)
      keys.each do |key|
        value = hash[key] || hash[key.to_sym]
        return value unless value.nil?
      end
      nil
    end

    def initialize(name, raw = {})
      @name = name
      @raw = raw
    end

    def validate!
      if limit_amount_min > limit_amount_max
        raise InvalidInputError,
              "#{name}: limit_amount_min #{limit_amount_min} > limit_amount_max #{limit_amount_max}"
      end
      self
    end

    def status
      value = field("status")
      value.nil? ? "active" : value.to_s
    end

    def active?
      status == "active"
    end

    def limit_amount_min
      number("limit_amount_min", 0)
    end

    def limit_amount_max
      number("limit_amount_max", UNLIMITED)
    end

    def daily_amount_limit
      number("daily_amount_limit", UNLIMITED)
    end

    def daily_approved_amount
      number("daily_approved_amount", 0)
    end

    def in_progress_count_limit
      number("in_progress_count_limit", UNLIMITED)
    end

    def in_progress_count
      number("in_progress_count", 0)
    end

    def in_progress_amount_limit
      number("in_progress_amount_limit", UNLIMITED)
    end

    def in_progress_amount
      number("in_progress_amount", 0)
    end

    # nil = список не задан, разрешены любые банки.
    # Пустой массив трактуем так же: это «поле не заполнили», а не «запретить всё».
    def banks
      list = field("banks")
      return nil if list.nil?

      normalized = Array(list).map { |bank| self.class.normalize_bank(bank) }.reject(&:empty?)
      normalized.empty? ? nil : normalized
    end

    def exclude_banks
      Array(field("exclude_banks")).map { |bank| self.class.normalize_bank(bank) }.reject(&:empty?)
    end

    def provider_margin_pct
      number("provider_margin_pct", 0)
    end

    def merchant_margin_pct
      raw_value = field("merchant_margin_pct")
      raw_value.nil? ? nil : to_number(raw_value, "merchant_margin_pct")
    end

    def allow_negative_agreement?
      value = field("allow_negative_agreement")
      value == true || value.to_s == "true"
    end

    # nil = терминалы не учитываем. Ноль — это реальный ноль свободных реквизитов.
    def available_requisites
      value = field("available_requisites")
      value.nil? ? nil : to_number(value, "available_requisites")
    end

    # Поля, которые команда задаёт сама. nil = ограничение/цель не заданы.
    def requests_per_minute_limit
      optional_number("requests_per_minute_limit")
    end

    def daily_turnover_min
      optional_number("daily_turnover_min")
    end

    def daily_turnover_max
      optional_number("daily_turnover_max")
    end

    def priority
      optional_number("priority")
    end

    def traffic_percentage
      optional_number("traffic_percentage")
    end

    def volume_share_pct
      optional_number("volume_share_pct")
    end

    def conversion_24h
      optional_number("conversion_24h")
    end

    def self.normalize_bank(bank)
      bank.to_s.downcase.strip
    end

    def ==(other)
      other.is_a?(Provider) && other.name == name
    end
    alias eql? ==

    def hash
      name.hash
    end

    def to_s
      name
    end

    private

    def field(key)
      self.class.fetch_any(raw, key)
    end

    def number(key, default)
      value = field(key)
      value.nil? ? default : to_number(value, key)
    end

    def optional_number(key)
      number(key, nil)
    end

    def to_number(value, key)
      return value if value.is_a?(Numeric)
      return Float(value) if value.is_a?(String) && !value.strip.empty?

      raise InvalidInputError, "#{name}: поле #{key} не число (#{value.inspect})"
    rescue ArgumentError, TypeError
      raise InvalidInputError, "#{name}: поле #{key} не число (#{value.inspect})"
    end
  end
end
