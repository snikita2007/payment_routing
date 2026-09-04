require_relative "../attempt"

module Routing
  module HardConstraints
    # Одна hard-проверка. #call возвращает Attempt со skipped, если провайдер не проходит,
    # и nil, если проходит. Ограничение, которое не задано (nil), никого не отсекает.
    class BaseCheck
      def call(_provider, _operation, _state)
        raise NotImplementedError, "#{self.class}#call"
      end

      def name
        self.class.name.split("::").last
      end

      private

      def skip(provider, reason, details)
        Attempt.skipped(provider.name, reason, details)
      end

      # Числа в details пишем без хвоста .0 — они уходят в отчёт для человека.
      def fmt(value)
        return value.to_s unless value.is_a?(Numeric)
        return "∞" if value == Float::INFINITY

        value == value.to_i ? value.to_i.to_s : format("%.2f", value)
      end
    end
  end
end
