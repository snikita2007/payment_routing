require_relative "base_check"

module Routing
  module HardConstraints
    # Лимит одновременных заявок по сумме.
    class InProgressAmountCheck < BaseCheck
      REASON = "in_progress_amount_limit".freeze

      def call(provider, operation, state)
        current = state.in_progress_amount(provider)
        projected = current + operation.amount
        limit = provider.in_progress_amount_limit
        return nil if projected <= limit

        skip(provider, REASON,
             "in_progress_amount #{fmt(current)} + #{fmt(operation.amount)} = #{fmt(projected)} " \
             "> in_progress_amount_limit #{fmt(limit)}")
      end
    end
  end
end
