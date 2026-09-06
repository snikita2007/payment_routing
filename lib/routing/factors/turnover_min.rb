require_relative "base_factor"

module Routing
  module Factors
    # M — минимальный дневной оборот, который провайдеру обещали набрать.
    # Пока обязательство не выполнено, провайдер получает надбавку; как только
    # оборот дотянут, фактор гаснет сам.
    class TurnoverMinFactor < BaseFactor
      KEY = "turnover_min".freeze

      def assess(provider, _operation, state)
        target = provider.daily_turnover_min
        return result(NEUTRAL, "daily_turnover_min не задан") if target.nil?
        return result(NEUTRAL, "daily_turnover_min нулевой — обязательства нет") if target <= 0

        current = state.daily_turnover(provider)
        value = clip((target - current) / (target + epsilon), 0.0, 1.0)

        if value.zero?
          return result(value, "минимальный оборот набран: #{fmt(current)} из #{fmt(target)}")
        end

        result(value, "до daily_turnover_min не хватает #{fmt(target - current)} " \
                      "(#{fmt(current)} из #{fmt(target)})")
      end
    end
  end
end
