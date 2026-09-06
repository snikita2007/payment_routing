require_relative "base_factor"

module Routing
  module Factors
    # L — свободная мощность. Дополняет hard-проверки in-progress: те отвечают «влезет или нет»,
    # а этот — «насколько провайдер уже занят». Загруженный на 90% формально проходит,
    # но отправлять к нему следующую заявку хуже, чем к свободному.
    class LoadFactor < BaseFactor
      KEY = "load".freeze

      def assess(provider, _operation, state)
        by_count = utilization(state.in_progress_count(provider), provider.in_progress_count_limit)
        by_amount = utilization(state.in_progress_amount(provider), provider.in_progress_amount_limit)
        busiest = [by_count, by_amount].max
        value = clip(1.0 - busiest, 0.0, 1.0)

        result(value, "загрузка in-progress #{pct(busiest * 100)} " \
                      "(#{fmt(state.in_progress_count(provider))}/#{fmt(provider.in_progress_count_limit)} шт, " \
                      "#{fmt(state.in_progress_amount(provider))}/#{fmt(provider.in_progress_amount_limit)} ₽)")
      end

      private

      def utilization(current, limit)
        return 0.0 if limit.nil? || limit == Float::INFINITY
        return 1.0 if limit <= 0

        clip(current / limit.to_f, 0.0, 1.0)
      end
    end
  end
end
