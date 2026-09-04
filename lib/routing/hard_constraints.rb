require_relative "attempt"
require_relative "hard_constraints/status_check"
require_relative "hard_constraints/amount_range_check"
require_relative "hard_constraints/daily_limit_check"
require_relative "hard_constraints/in_progress_count_check"
require_relative "hard_constraints/in_progress_amount_check"
require_relative "hard_constraints/bank_filter_check"
require_relative "hard_constraints/margin_check"
require_relative "hard_constraints/requisites_check"
require_relative "hard_constraints/rate_limit_check"

module Routing
  # Условия допуска провайдера к роутингу: «можно ли вообще отправить эту заявку сюда».
  # Применяются до выбора стратегии, ни одна из них не может быть перевешена скором.
  #
  # Добавить правило = добавить класс с #call и строку в DEFAULT_CHECKS.
  module HardConstraints
    # Порядок совпадает с таблицей hard-constraints из ТЗ и определяет, какая причина
    # попадёт в attempts, если провайдер нарушает сразу несколько условий.
    DEFAULT_CHECKS = [
      StatusCheck,
      AmountRangeCheck,
      DailyLimitCheck,
      InProgressCountCheck,
      InProgressAmountCheck,
      BankFilterCheck,
      MarginCheck,
      RequisitesCheck,
      RateLimitCheck
    ].freeze

    # Результат фильтрации: кто допущен и почему исключены остальные.
    Result = Struct.new(:eligible, :rejections, keyword_init: true) do
      def empty?
        eligible.empty?
      end

      def attempts
        rejections
      end
    end

    class Filter
      attr_reader :checks

      def initialize(checks: DEFAULT_CHECKS)
        @checks = checks.map { |check| check.is_a?(Class) ? check.new : check }
      end

      # Первая сработавшая проверка и есть причина отказа: одна заявка — одна понятная
      # строка в attempts, как в примере формата из ТЗ.
      def evaluate(provider, operation, state)
        checks.each do |check|
          attempt = check.call(provider, operation, state)
          return attempt if attempt
        end
        nil
      end

      def eligible?(provider, operation, state)
        evaluate(provider, operation, state).nil?
      end

      # Порядок провайдеров сохраняется как есть: ранжированием занимается скорер.
      def eligible(providers, operation, state)
        passed = []
        rejections = []

        providers.each do |provider|
          rejection = evaluate(provider, operation, state)
          rejection ? rejections << rejection : passed << provider
        end

        Result.new(eligible: passed, rejections: rejections)
      end
    end

    def self.default
      @default ||= Filter.new
    end

    def self.eligible(providers, operation, state)
      default.eligible(providers, operation, state)
    end

    def self.evaluate(provider, operation, state)
      default.evaluate(provider, operation, state)
    end
  end
end
