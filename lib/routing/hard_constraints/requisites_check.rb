require_relative "base_check"

module Routing
  module HardConstraints
    # Свободные реквизиты/терминалы. Ноль — реальный ноль, отсутствие поля — «не учитываем».
    class RequisitesCheck < BaseCheck
      REASON = "no_available_requisites".freeze

      def call(provider, _operation, _state)
        available = provider.available_requisites
        return nil if available.nil? || available > 0

        skip(provider, REASON, "available_requisites #{fmt(available)}")
      end
    end
  end
end
