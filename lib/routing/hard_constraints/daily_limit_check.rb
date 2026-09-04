require_relative "base_check"

module Routing
  module HardConstraints
    # Дневной максимум по обороту. Текущий оборот берём из состояния: по ходу очереди
    # он уходит вперёд от значения в providers.json.
    #
    # daily_turnover_max — то же ограничение, заданное командой отдельным полем;
    # если оно есть, действует более строгое из двух.
    class DailyLimitCheck < BaseCheck
      REASON = "daily_limit_exceeded".freeze

      def call(provider, operation, state)
        used = state.daily_approved_amount(provider)
        projected = used + operation.amount

        limit, source = effective_limit(provider)
        return nil if projected <= limit

        skip(provider, REASON,
             "#{fmt(used)} + #{fmt(operation.amount)} = #{fmt(projected)} > #{source} #{fmt(limit)}")
      end

      private

      def effective_limit(provider)
        candidates = [[provider.daily_amount_limit, "daily_amount_limit"]]
        candidates << [provider.daily_turnover_max, "daily_turnover_max"] if provider.daily_turnover_max
        candidates.min_by(&:first)
      end
    end
  end
end
