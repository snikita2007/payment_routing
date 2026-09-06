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

      name = fetch_any(hash, "payment_system", "name", "provider", "id", "code")
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

    # Провайдера повсюду принимаем и объектом, и просто именем: состояние, статистика
    # и симулятор ключуются по имени, а звать их удобно и тем и другим.
    def self.name_of(provider)
      provider.is_a?(Provider) ? provider.name : provider.to_s
    end

    def initialize(name, raw = {})
      @name = name
      @raw = raw
      # Поля читаются десятками раз на заявку (одни только hard-проверки дёргают их
      # на каждого провайдера), а объект после создания не меняется — разбираем однажды.
      @fields = {}
      @numbers = {}
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
      return @banks if defined?(@banks)

      @banks = normalize_bank_list(field("banks"))
    end

    # В боевых данных exclude_banks — булев флаг: он переключает banks из белого
    # списка в чёрный (см. scripts/validate_10.rb). В ТЗ то же поле показано как
    # отдельный список исключений, поэтому поддерживаем обе формы.
    def exclude_banks
      return @exclude_banks if defined?(@exclude_banks)

      value = field("exclude_banks")
      @exclude_banks = value == true ? (banks || []) : (normalize_bank_list(value) || [])
    end

    # true, если banks нужно читать как чёрный список, а не белый.
    def banks_are_blacklist?
      field("exclude_banks") == true
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

    # conversion_24h, приведённая к доле [0, 1]. nil, если поле не задано.
    #
    # В providers.json это доля (0.87), но то же поле легко приходит в процентах (87),
    # и делить одно на другое одинаково нельзя. Граница — единица; на 0.5 или 1 правило
    # принципиально угадать не может. Клип нужен для мусора: 150 без него дало бы 1.5,
    # и фактор конверсии с весом 0.27 внёс бы 0.40, выйдя за собственный бюджет весов.
    #
    # Живёт здесь, а не в скорере, потому что читателей двое: скорер и симулятор исхода.
    # Разойдись их трактовки — симулятор моделировал бы не того провайдера, которого
    # выбрал скорер, и заметить это по выходу было бы нечем.
    def conversion_rate
      value = conversion_24h
      return nil if value.nil?

      (value > 1 ? value / 100.0 : value.to_f).clamp(0.0, 1.0)
    end

    def avg_latency_sec
      optional_number("avg_latency_sec")
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
      @fields.fetch(key) { @fields[key] = self.class.fetch_any(raw, key) }
    end

    # Каждый ключ читается ровно с одним дефолтом, поэтому кешировать можно по имени поля.
    def number(key, default)
      @numbers.fetch(key) do
        value = field(key)
        @numbers[key] = value.nil? ? default : to_number(value, key)
      end
    end

    def optional_number(key)
      number(key, nil)
    end

    def normalize_bank_list(value)
      return nil if value.nil? || value == true || value == false

      normalized = Array(value).map { |bank| self.class.normalize_bank(bank) }.reject(&:empty?)
      normalized.empty? ? nil : normalized
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
