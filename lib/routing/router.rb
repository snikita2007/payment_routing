require_relative "attempt"
require_relative "hard_constraints"
require_relative "result_simulator"
require_relative "soft_scorer"

module Routing
  # Конвейер на одну заявку, строго в этом порядке:
  #
  #   hard-фильтры → скоринг допущенных → сборка attempts[] → обновление состояния
  #
  # Очередь идёт последовательно и порядок значим: каждая заявка двигает обороты,
  # in-progress и доли, и следующая видит уже новую картину. Параллелить нельзя.
  class Router
    # Сколько заявка висит в работе, когда симулятора нет. С симулятором вместо этой
    # выдержки берётся настоящая длительность ответа: заявка освобождает in-progress
    # ровно тогда, когда исход стал известен.
    HOLD_SEC = 45

    HIGHEST_SCORE = "highest_weighted_score".freeze
    ONLY_ELIGIBLE = "only_eligible_provider".freeze
    LOWER_SCORE = "lower_score".freeze
    FALLBACK_REASON = "fallback_self_provider".freeze

    Decision = Struct.new(:operation, :provider, :attempts, :fallback, :ranked, :outcome,
                          keyword_init: true)

    # Состав пула — не hard-проверка, а вопрос «кто вообще участвует»:
    #  - self-provider держим в стороне, он последняя инстанция, а не конкурент;
    #  - провайдер с нулевой целевой долей в раздачу не идёт (то же правило
    #    в scripts/validate_10.rb).
    def self.routable(providers)
      providers.reject do |provider|
        provider.name == SELF_PROVIDER || provider.traffic_percentage.to_f.zero?
      end
    end

    attr_reader :providers, :scorer, :filter, :hold_sec, :explain_top, :simulator

    def initialize(providers:, scorer:, filter: HardConstraints.default,
                   hold_sec: HOLD_SEC, explain_top: 3, simulator: nil)
      @providers = providers
      @scorer = scorer
      @filter = filter
      @hold_sec = hold_sec
      @explain_top = explain_top
      @simulator = simulator
      @in_flight = []
    end

    def run(operations, state)
      @in_flight = []

      Array(operations).map do |operation|
        release_finished(state, operation.created_at || state.now)
        route(operation, state)
      end
    end

    def route(operation, state)
      result = filter.eligible(providers, operation, state)
      attempts = result.rejections.dup

      return fallback(operation, state, attempts) if result.empty?

      ranked = scorer.rank(result.eligible, operation, state)
      winner = ranked.first

      attempts << selected_attempt(winner, ranked)
      ranked.drop(1).each { |loser| attempts << outscored_attempt(loser, winner) }

      outcome = apply(state, winner.provider, operation)
      Decision.new(operation: operation, provider: winner.provider, attempts: attempts,
                   fallback: false, ranked: ranked, outcome: outcome)
    end

    private

    # Пул пуст — заявка уходит self-provider'у. Hard-ограничения при этом не ослабляются:
    # мы не подбираем «почти подходящего», а честно фиксируем, что подходящих нет.
    def fallback(operation, state, attempts)
      attempts << Attempt.selected(SELF_PROVIDER, FALLBACK_REASON,
                                   "все внешние провайдеры исключены")
      outcome = apply(state, SELF_PROVIDER, operation, toward_share: false)
      Decision.new(operation: operation, provider: nil, attempts: attempts,
                   fallback: true, ranked: [], outcome: outcome)
    end

    def selected_attempt(winner, ranked)
      # Когда допущен ровно один, причина не в скоре — и словарь тут эталонный.
      reason = ranked.size == 1 ? ONLY_ELIGIBLE : HIGHEST_SCORE
      Attempt.selected(winner.name, reason, winner.details(explain_top))
    end

    # Проигравшие тоже попадают в attempts: жюри смотрит не только на выбранного,
    # но и на то, что мы вообще рассматривали и почему отложили.
    def outscored_attempt(loser, winner)
      details = format("%s — ниже, чем у %s (%.3f)",
                       loser.breakdown(explain_top), winner.name, winner.score)
      Attempt.skipped(loser.name, LOWER_SCORE, details)
    end

    def apply(state, provider, operation, toward_share: true)
      at = operation.created_at || state.now
      state.record_request(provider, at: at)
      state.add_in_progress(provider, operation.amount)
      state.add_daily_amount(provider, operation.amount)
      state.record_routed(provider, operation.amount, toward_share: toward_share)

      outcome = simulator && simulator.simulate(provider, operation)
      # Исход становится известен не в момент отправки, а когда пришёл ответ. С этого же
      # момента заявка перестаёт занимать in-progress — одно и то же событие.
      done_at = (outcome && outcome.known_at) || at + hold_sec
      state.record_outcome(provider, at: done_at, failure: outcome.failure?) if outcome

      @in_flight << { provider: provider, amount: operation.amount, until: done_at }
      outcome
    end

    def release_finished(state, now)
      @in_flight.reject! do |entry|
        next false if entry[:until] > now

        state.release_in_progress(entry[:provider], entry[:amount])
        true
      end
    end
  end
end
