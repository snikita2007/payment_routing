require_relative "conversion_stats"

module Routing
  # Симулятор исхода заявки: approved / rejected / expired плюс latency_sec.
  #
  # Нужен по двум причинам сразу. Во-первых, simulated_result и latency_sec — обязательные поля
  # routing_decisions_test.json. Во-вторых, без исходов нечем кормить штраф за недавние сбои:
  # единственный другой источник, operations_history.csv, отстоит от очереди на 20 часов, и при
  # периоде полураспада в десятки секунд его вес — машинный ноль.
  #
  # Вероятность одобрения берётся из ConversionStats, то есть **не зависит от активного профиля
  # скоринга**. Если бы симулятор читал её из вклада фактора conversion, смена весов меняла бы
  # не только выбор провайдера, но и сам симулируемый мир, и сравнивать профили было бы не с чем.
  class ResultSimulator
    APPROVED = ConversionStats::APPROVED
    REJECTED = ConversionStats::REJECTED
    EXPIRED = ConversionStats::EXPIRED
    STATUSES = [APPROVED, REJECTED, EXPIRED].freeze

    DEFAULT_SEED = 20_260_730
    DEFAULT_EXPIRED_SHARE = 0.5
    # Когда о задержках не известно ничего: сколько-нибудь правдоподобные секунды.
    FALLBACK_LATENCY = { APPROVED => 45, REJECTED => 40, EXPIRED => 570 }.freeze

    # known_at — момент, когда исход стал известен; именно с него он влияет на следующие заявки.
    Outcome = Struct.new(:status, :latency_sec, :known_at, :approved, keyword_init: true) do
      def approved?
        approved
      end

      def failure?
        !approved
      end
    end

    attr_reader :stats, :seed, :expired_share, :latency_source

    def initialize(stats: nil, seed: DEFAULT_SEED, expired_share: nil, latency_source: "history")
      @stats = stats
      @seed = seed
      @expired_share = expired_share
      @latency_source = latency_source.to_s
    end

    def simulate(provider, operation)
      random = random_for(provider, operation)
      approved = random.rand < approve_probability(provider, operation)
      status = approved ? APPROVED : failure_status(provider, random)
      latency = latency_for(provider, status, random)
      started = operation.created_at

      Outcome.new(
        status: status,
        latency_sec: latency,
        known_at: started && started + latency,
        approved: approved
      )
    end

    def approve_probability(provider, operation)
      from_history = stats && !stats.empty? &&
                     stats.estimate(provider, bank: operation.bank, amount: operation.amount,
                                              card_brand: operation.card_brand).value
      return from_history.clamp(0.0, 1.0) if from_history

      declared = provider.respond_to?(:conversion_rate) ? provider.conversion_rate : nil
      declared || ConversionStats::NO_HISTORY_RATE
    end

    private

    # Один и тот же seed обязан давать один и тот же прогон, иначе ни сравнить профили,
    # ни зафиксировать результат тестом.
    #
    # String#hash для ключа не годится: в Ruby он рандомизируется при каждом запуске процесса,
    # и «детерминированный» прогон расходился бы от запуска к запуску. Берём FNV-1a — пять строк
    # арифметики вместо зависимости, ровно по той же причине, по которой не тянем csv.
    def random_for(provider, operation)
      Random.new(fnv1a("#{seed}:#{operation.id}:#{Provider.name_of(provider)}"))
    end

    FNV_OFFSET = 0xcbf29ce484222325
    FNV_PRIME = 0x100000001b3
    FNV_MASK = 0xffffffffffffffff

    def fnv1a(text)
      text.each_byte.reduce(FNV_OFFSET) do |hash, byte|
        ((hash ^ byte) * FNV_PRIME) & FNV_MASK
      end
    end

    def failure_status(provider, random)
      random.rand < expired_share_for(provider) ? EXPIRED : REJECTED
    end

    def expired_share_for(provider)
      return expired_share.to_f if expired_share

      (stats && stats.expired_share(provider)) || DEFAULT_EXPIRED_SHARE
    end

    # Задержку берём из истории по тому же статусу: у expired она на порядок больше,
    # и общая выборка дала бы середину, которой не бывает.
    def latency_for(provider, status, random)
      base = base_latency(provider, status)
      jittered = base * (0.7 + 0.6 * random.rand)
      [jittered.round, 1].max
    end

    def base_latency(provider, status)
      if latency_source != "declared" && stats
        measured = stats.median_latency_for(provider, status)
        return measured if measured
      end

      declared = provider.respond_to?(:avg_latency_sec) ? provider.avg_latency_sec : nil
      return FALLBACK_LATENCY.fetch(status) if declared.nil?

      # Заявленное время описывает нормальный ответ; просрочка — это другой режим,
      # и растягивать её из того же числа честнее, чем делать вид, что она такая же.
      status == EXPIRED ? declared * expired_stretch : declared
    end

    def expired_stretch
      FALLBACK_LATENCY.fetch(EXPIRED).fdiv(FALLBACK_LATENCY.fetch(APPROVED))
    end

  end
end
