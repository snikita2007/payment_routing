require_relative "base_check"

module Routing
  module HardConstraints
    # Лимит одновременных заявок по количеству.
    class InProgressCountCheck < BaseCheck
      REASON = "in_progress_count_limit".freeze

      def call(provider, _operation, state)
        current = state.in_progress_count(provider)
        limit = provider.in_progress_count_limit
        return nil if current + 1 <= limit

        skip(provider, REASON,
             "in_progress_count #{fmt(current)} + 1 > in_progress_count_limit #{fmt(limit)}")
      end
    end
  end
end
