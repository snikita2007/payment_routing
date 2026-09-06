require_relative "share_factor"

module Routing
  module Factors
    # D_t — целевая доля по количеству заявок.
    # Недобравший долю поднимается, перебравший опускается; за прогон это стягивает
    # фактическое распределение к traffic_percentage.
    class TrafficShareFactor < ShareFactor
      KEY = "traffic_share".freeze

      private

      def label
        "доля по количеству"
      end

      def target_field
        "traffic_percentage"
      end

      def target_for(provider)
        provider.traffic_percentage
      end

      def current_share(state, provider)
        state.count_share_pct(provider)
      end

      def total_for(state)
        state.total_routed_count
      end

      def actual_for(state, provider)
        state.routed_count(provider)
      end

      def unit_for(_operation)
        1
      end
    end
  end
end
