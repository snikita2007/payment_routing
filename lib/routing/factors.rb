require_relative "conversion_stats"
require_relative "format"

require_relative "factors/base_factor"
require_relative "factors/share_factor"
require_relative "factors/traffic_share"
require_relative "factors/volume_share"
require_relative "factors/conversion"
require_relative "factors/priority"
require_relative "factors/turnover_min"
require_relative "factors/load"
require_relative "factors/speed"
require_relative "factors/recent_failure"

module Routing
  # Soft-факторы: слагаемые формулы ранжирования.
  #
  #   Score = w_t·D_t + w_v·D_v + w_c·C + w_p·P + w_m·M + w_l·L + w_s·Speed − w_f·RecentFailure
  #
  # Один фактор — один класс в lib/routing/factors/ с методом #assess. Чтобы добавить правило,
  # нужно ровно три вещи: класс, строка в REGISTERED ниже и вес в config/scoring.yml.
  # Ни SoftScorer, ни Router при этом не меняются — они знают только про реестр.
  #
  # Фактор с нулевым весом не создаётся вовсе: нулевой вес — это «правило выключено»,
  # а не «правило посчитали и умножили на ноль».
  module Factors
    # Порядок здесь ни на что не влияет — реестр адресуется по ключу (KEY у каждого класса).
    REGISTERED = [
      TrafficShareFactor,   # D_t — целевая доля по количеству заявок
      VolumeShareFactor,    # D_v — целевая доля по объёму денег
      ConversionFactor,     # C   — вероятность одобрения
      PriorityFactor,       # P   — позиция в каскаде
      TurnoverMinFactor,    # M   — недобор обещанного дневного оборота
      LoadFactor,           # L   — свободная мощность
      SpeedFactor,          # Speed — скорость ответа
      RecentFailureFactor   # штраф за свежие сбои (единственный, кто уходит в минус)
    ].freeze

    REGISTRY = {}

    def self.register(klass)
      REGISTRY[klass::KEY] = klass
    end

    def self.keys
      REGISTRY.keys
    end

    def self.fetch(key)
      REGISTRY[key.to_s] ||
        raise(ArgumentError, "неизвестный фактор #{key.inspect}; есть: #{keys.sort.join(', ')}")
    end

    def self.build(key, options: {}, epsilon: 1.0e-06, stats: nil)
      fetch(key).new(options: options, epsilon: epsilon, stats: stats)
    end

    REGISTERED.each { |klass| register(klass) }
  end
end
