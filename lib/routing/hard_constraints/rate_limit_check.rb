require_relative "base_check"

module Routing
  module HardConstraints
    # Интенсивность: не больше requests_per_minute_limit заявок в скользящем окне 60 секунд.
    # Поле задаёт команда, без него ограничения нет.
    class RateLimitCheck < BaseCheck
      REASON = "rate_limit_exceeded".freeze

      def call(provider, operation, state)
        limit = provider.requests_per_minute_limit
        return nil if limit.nil?

        at = operation.created_at || state.now
        recent = state.requests_in_last_minute(provider, at: at)
        return nil if recent < limit

        skip(provider, REASON,
             "#{fmt(recent)} заявок за последние 60 сек >= requests_per_minute_limit #{fmt(limit)}")
      end
    end
  end
end
