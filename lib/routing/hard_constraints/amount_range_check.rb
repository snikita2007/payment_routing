require_relative "base_check"

module Routing
  module HardConstraints
    # Диапазон суммы чека. Границы включительно.
    class AmountRangeCheck < BaseCheck
      # Словарь причин задан эталоном организаторов (data/reference_decisions.json).
      BELOW = "amount_below_minimum".freeze
      ABOVE = "amount_exceeds_limit".freeze

      def call(provider, operation, _state)
        amount = operation.amount

        if amount < provider.limit_amount_min
          return skip(provider, BELOW,
                      "#{fmt(amount)} < limit_amount_min #{fmt(provider.limit_amount_min)}")
        end

        if amount > provider.limit_amount_max
          return skip(provider, ABOVE,
                      "#{fmt(amount)} > limit_amount_max #{fmt(provider.limit_amount_max)}")
        end

        nil
      end
    end
  end
end
