require_relative "base_check"

module Routing
  module HardConstraints
    # Статус провайдера: работаем только с active.
    class StatusCheck < BaseCheck
      REASON = "provider_inactive".freeze

      def call(provider, _operation, _state)
        return nil if provider.active?

        skip(provider, REASON, "status #{provider.status} != active")
      end
    end
  end
end
