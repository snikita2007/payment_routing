require_relative "base_check"

module Routing
  module HardConstraints
    # Банковский фильтр.
    #
    # Список banks читается как белый или как чёрный — в зависимости от exclude_banks:
    # в боевых данных это булев флаг-переключатель, в ТЗ — отдельный список исключений.
    # Если фильтра нет вовсе, провайдер работает с любым банком.
    class BankFilterCheck < BaseCheck
      NOT_IN_LIST = "bank_not_in_list".freeze
      EXCLUDED = "bank_excluded".freeze
      UNKNOWN_BANK = "bank_unknown".freeze

      def call(provider, operation, _state)
        allowed = provider.banks_are_blacklist? ? nil : provider.banks
        excluded = provider.exclude_banks
        return nil if allowed.nil? && excluded.empty?

        # Банк не указан, а провайдер фильтрует по банкам — допустить нельзя.
        unless operation.bank?
          return skip(provider, UNKNOWN_BANK, "у заявки не указан банк, а провайдер фильтрует по банкам")
        end

        bank = operation.normalized_bank

        if excluded.include?(bank)
          return skip(provider, EXCLUDED, "#{bank} в exclude_banks [#{excluded.join(', ')}]")
        end

        if allowed && !allowed.include?(bank)
          return skip(provider, NOT_IN_LIST, "#{bank} не в banks [#{allowed.join(', ')}]")
        end

        nil
      end
    end
  end
end
