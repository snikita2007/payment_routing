require_relative "base_factor"

module Routing
  module Factors
    # P — позиция в каскаде. priority 1 → 1.0, 2 → 0.5, 3 → 0.33.
    class PriorityFactor < BaseFactor
      KEY = "priority".freeze

      def assess(provider, _operation, _state)
        priority = provider.priority
        return result(NEUTRAL, "priority не задан") if priority.nil? || priority <= 0

        value = 1.0 / priority
        result(value, "priority #{fmt(priority)} → #{format('%.2f', value)}")
      end
    end
  end
end
