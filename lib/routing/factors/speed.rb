require_relative "base_factor"

module Routing
  module Factors
    # Speed — скорость провайдера. Шкала абсолютная: latency_scale_sec секунд считаем
    # «совсем медленно». Min-max по пулу здесь не годится — он превратил бы разницу
    # 29 с против 38 с в 1.0 против 0.0 и менял бы оценку одного провайдера
    # в зависимости от того, кто ещё прошёл фильтры на этой заявке.
    class SpeedFactor < BaseFactor
      KEY = "speed".freeze

      DEFAULT_SCALE_SEC = 120.0

      def assess(provider, _operation, _state)
        latency, source = latency_for(provider)
        return result(NEUTRAL, "нет данных о времени ответа") if latency.nil?

        value = clip(1.0 - latency / scale, 0.0, 1.0)
        result(value, "#{source} #{fmt(latency)} с из #{fmt(scale)} → #{format('%.2f', value)}")
      end

      private

      def scale
        value = options.fetch("latency_scale_sec", DEFAULT_SCALE_SEC).to_f
        value.positive? ? value : DEFAULT_SCALE_SEC
      end

      # source: declared — avg_latency_sec из providers.json, история как запасной вариант
      #         history  — наоборот, верим замерам, а не заявленному
      #
      # Различие не умозрительное: providers.json объявляет quickpay самым быстрым (29 с),
      # а по истории медиана успешных заявок у него выше, чем у vipay.
      def latency_for(provider)
        declared = [provider.avg_latency_sec, "avg_latency_sec"]
        measured = [stats && stats.median_latency(provider), "медиана по истории"]
        order = options.fetch("source", "declared").to_s == "history" ? [measured, declared] : [declared, measured]

        order.find { |value, _| !value.nil? } || [nil, nil]
      end
    end
  end
end
