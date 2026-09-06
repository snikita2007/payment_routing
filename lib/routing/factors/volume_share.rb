require_relative "share_factor"

module Routing
  module Factors
    # D_v — то же самое, но доля считается в деньгах.
    # Расходится с D_t не случайно: один чек на 150 000 весит как двадцать по 8 000,
    # и провайдер, набравший свою долю заявок, может недобирать половину объёма.
    class VolumeShareFactor < ShareFactor
      KEY = "volume_share".freeze

      private

      def label
        "доля по объёму"
      end

      def target_field
        "volume_share_pct"
      end

      def target_for(provider)
        provider.volume_share_pct
      end

      def current_share(state, provider)
        state.volume_share_pct(provider)
      end

      def total_for(state)
        state.total_routed_amount
      end

      def actual_for(state, provider)
        state.routed_amount(provider)
      end

      # Шаг измеряется суммой текущей заявки: недобор в один такой чек и есть единица.
      def unit_for(operation)
        operation.amount
      end
    end
  end
end
