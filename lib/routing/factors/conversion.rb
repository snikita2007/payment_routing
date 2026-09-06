require_relative "base_factor"

module Routing
  module Factors
    # C — вероятность одобрения. Источник переключается конфигом:
    # history (срезы из CSV со сглаживанием), declared (conversion_24h) или их смесь.
    class ConversionFactor < BaseFactor
      KEY = "conversion".freeze

      HISTORY = "history".freeze
      DECLARED = "declared".freeze
      BLEND = "blend".freeze

      def assess(provider, operation, _state)
        case source
        when DECLARED then declared(provider)
        when BLEND then blend(provider, operation)
        else history(provider, operation)
        end
      end

      private

      def source
        options.fetch("source", HISTORY).to_s
      end

      def blend_weight
        options.fetch("blend_history_weight", 0.7).to_f.clamp(0.0, 1.0)
      end

      def history(provider, operation)
        return declared(provider) if stats.nil?

        estimate = stats.estimate(
          provider,
          bank: operation.bank,
          amount: operation.amount,
          card_brand: operation.card_brand
        )
        result(estimate.value, "конверсия по истории #{estimate}")
      end

      def declared(provider)
        value = provider.conversion_rate
        return result(UNKNOWN_PROBABILITY, "conversion_24h не задан, берём #{UNKNOWN_PROBABILITY}") if value.nil?

        result(value, "conversion_24h #{format('%.3f', value)}")
      end

      def blend(provider, operation)
        from_history = history(provider, operation)
        from_declared = declared(provider)
        weight = blend_weight
        value = weight * from_history.value + (1 - weight) * from_declared.value

        result(value, format("конверсия %.3f = %.2f×история %.3f + %.2f×заявленная %.3f",
                             value, weight, from_history.value, 1 - weight, from_declared.value))
      end

    end
  end
end
