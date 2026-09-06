require_relative "attempt"
require_relative "format"

module Routing
  # Условия допуска провайдера к роутингу: «можно ли вообще отправить эту заявку сюда».
  #
  # Применяются до выбора стратегии, и ни одну из них нельзя перевесить скором — это
  # главный инвариант решения. Soft-факторы ранжируют только тех, кто уже прошёл сюда.
  #
  # Одна проверка — один класс с методом #call, который возвращает Attempt со skipped
  # при отказе и nil при проходе. Чтобы добавить правило, нужны класс и строка
  # в DEFAULT_CHECKS; ни Filter, ни Router при этом не меняются.
  #
  # Ограничение, которое не задано (nil), никого не отсекает: решение обязано работать
  # на непропатченном providers.json.
  #
  # Проверки лежат одним файлом намеренно. Каждая — полтора десятка строк, и все они
  # делят общий словарь причин (amount_exceeds_limit, bank_not_in_list, …), который
  # обязан совпадать с эталоном организаторов. Набор причин виден целиком только так.
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
        Format.number(value)
      end
    end

    # Статус провайдера: работаем только с active.
    class StatusCheck < BaseCheck
      def call(provider, _operation, _state)
        return nil if provider.active?

        skip(provider, "provider_inactive", "status #{provider.status} != active")
      end
    end

    # Диапазон суммы чека. Границы включительно.
    class AmountRangeCheck < BaseCheck
      # Словарь причин задан эталоном организаторов (data/reference_decisions.json).
      BELOW = "amount_below_minimum".freeze
      ABOVE = "amount_exceeds_limit".freeze

      def call(provider, operation, _state)
        amount = operation.amount

        if amount < provider.limit_amount_min
          return skip(provider, BELOW,
                      "#{fmt(amount)} < limit_amount_min #{fmt(provider.limit_amount_min)}")
        end

        if amount > provider.limit_amount_max
          return skip(provider, ABOVE,
                      "#{fmt(amount)} > limit_amount_max #{fmt(provider.limit_amount_max)}")
        end

        nil
      end
    end

    # Дневной максимум по обороту. Текущий оборот берём из состояния: по ходу очереди
    # он уходит вперёд от значения в providers.json.
    #
    # daily_turnover_max — то же ограничение, заданное командой отдельным полем;
    # если оно есть, действует более строгое из двух.
    class DailyLimitCheck < BaseCheck
      def call(provider, operation, state)
        used = state.daily_turnover(provider)
        projected = used + operation.amount

        limit, source = effective_limit(provider)
        return nil if projected <= limit

        skip(provider, "daily_limit_exceeded",
             "#{fmt(used)} + #{fmt(operation.amount)} = #{fmt(projected)} > #{source} #{fmt(limit)}")
      end

      private

      def effective_limit(provider)
        candidates = [[provider.daily_amount_limit, "daily_amount_limit"]]
        candidates << [provider.daily_turnover_max, "daily_turnover_max"] if provider.daily_turnover_max
        candidates.min_by(&:first)
      end
    end

    # Лимит одновременных заявок по количеству.
    class InProgressCountCheck < BaseCheck
      def call(provider, _operation, state)
        current = state.in_progress_count(provider)
        projected = current + 1
        limit = provider.in_progress_count_limit
        return nil if projected <= limit

        skip(provider, "in_progress_count_limit",
             "in_progress_count #{fmt(current)} + 1 > in_progress_count_limit #{fmt(limit)}")
      end
    end

    # Лимит одновременных заявок по сумме.
    class InProgressAmountCheck < BaseCheck
      def call(provider, operation, state)
        current = state.in_progress_amount(provider)
        projected = current + operation.amount
        limit = provider.in_progress_amount_limit
        return nil if projected <= limit

        skip(provider, "in_progress_amount_limit",
             "in_progress_amount #{fmt(current)} + #{fmt(operation.amount)} = #{fmt(projected)} " \
             "> in_progress_amount_limit #{fmt(limit)}")
      end
    end

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

    # Маржа: провайдер не должен стоить дороже, чем берёт мерчант,
    # если только с ним не согласована работа в минус.
    #
    # merchant_margin_pct ищем сперва у заявки, затем у провайдера.
    # Если его нет нигде — сравнивать не с чем, проверка пропускается.
    class MarginCheck < BaseCheck
      def call(provider, operation, _state)
        return nil if provider.allow_negative_agreement?

        merchant = operation.merchant_margin_pct || provider.merchant_margin_pct
        return nil if merchant.nil?

        return nil if provider.provider_margin_pct <= merchant

        skip(provider, "negative_margin",
             "provider_margin_pct #{fmt(provider.provider_margin_pct)} > " \
             "merchant_margin_pct #{fmt(merchant)}")
      end
    end

    # Свободные реквизиты/терминалы. Ноль — реальный ноль, отсутствие поля — «не учитываем».
    class RequisitesCheck < BaseCheck
      def call(provider, _operation, _state)
        available = provider.available_requisites
        return nil if available.nil? || available > 0

        skip(provider, "no_available_requisites", "available_requisites #{fmt(available)}")
      end
    end

    # Интенсивность: не больше requests_per_minute_limit заявок в скользящем окне 60 секунд.
    # Поле задаёт команда, без него ограничения нет.
    class RateLimitCheck < BaseCheck
      def call(provider, operation, state)
        limit = provider.requests_per_minute_limit
        return nil if limit.nil?

        at = operation.created_at || state.now
        recent = state.requests_in_last_minute(provider, at: at)
        return nil if recent < limit

        skip(provider, "rate_limit_exceeded",
             "#{fmt(recent)} заявок за последние 60 сек >= requests_per_minute_limit #{fmt(limit)}")
      end
    end

    # Порядок совпадает с таблицей hard-constraints из ТЗ и решает, какая именно причина
    # попадёт в attempts, если провайдер нарушает сразу несколько условий: берётся первая
    # сработавшая.
    DEFAULT_CHECKS = [
      StatusCheck,             # провайдер вообще работает?
      AmountRangeCheck,        # сумма чека в диапазоне
      DailyLimitCheck,         # дневной оборот не выйдет за лимит
      InProgressCountCheck,    # свободен слот по количеству заявок в работе
      InProgressAmountCheck,   # свободен слот по сумме заявок в работе
      BankFilterCheck,         # банк заявки разрешён
      MarginCheck,             # не уходим в минус по марже
      RequisitesCheck,         # есть свободные реквизиты
      RateLimitCheck           # не превышена интенсивность запросов
    ].freeze

    # Результат фильтрации: кто допущен и почему исключены остальные.
    # Отказы уже готовыми Attempt'ами — их и увидит жюри в attempts[].
    Result = Struct.new(:eligible, :rejections, keyword_init: true) do
      def empty?
        eligible.empty?
      end
    end

    # Прогоняет провайдеров через список проверок. Сам список — не его дело:
    # он приходит снаружи, а порядок задан в DEFAULT_CHECKS.
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

    # Один общий Filter на процесс: проверки не хранят состояния, создавать их на заявку незачем.
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
