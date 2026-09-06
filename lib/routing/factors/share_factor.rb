require_relative "base_factor"

module Routing
  module Factors
    # Общее для двух факторов целевой доли: обе считают одно и то же отклонение,
    # разница только в том, что мерить — заявки или деньги.
    #
    # mode: expected — через ожидаемое количество (по умолчанию)
    # mode: ratio    — буквально по формуле, через доли в процентах
    class ShareFactor < BaseFactor
      EXPECTED = "expected".freeze
      RATIO = "ratio".freeze

      def assess(provider, operation, state)
        target = target_for(provider)
        return result(NEUTRAL, "#{target_field} не задан") if target.nil?

        current = current_share(state, provider)
        value = mode == RATIO ? ratio_value(target, current) : expected_value(target, operation, state, provider)

        result(value, explain_text(target, current, value))
      end

      private

      def mode
        options.fetch("mode", EXPECTED).to_s
      end

      def ratio_value(target, current)
        ratio_deviation(target, current)
      end

      def expected_value(target, operation, state, provider)
        unit = unit_for(operation)
        expected = target / 100.0 * (total_for(state) + unit)
        expected_deviation(expected, actual_for(state, provider), unit)
      end

      def explain_text(target, current, value)
        gap = (target - current).abs
        word = value.negative? ? "перебор" : "недобор"

        "#{label}: цель #{fmt(target)}%, факт #{pct(current)} (#{word} #{fmt(gap)} п.п.)"
      end
    end
  end
end
