require_relative "conversion_stats"
require_relative "data_loader"
require_relative "provider_overrides"
require_relative "result_simulator"
require_relative "router"
require_relative "routing_state"
require_relative "scoring_config"
require_relative "soft_scorer"

module Routing
  # Сборка конвейера и один прогон очереди.
  #
  #   конфиг → провайдеры (+ свои поля) → история → скорер → роутер → состояние → решения
  #
  # Живёт в lib, а не в bin, по двум причинам: чтобы порядок сборки читался одним экраном
  # и чтобы им могли пользоваться и bin/route.rb, и тесты, и будущий генератор отчёта.
  #
  # Наружу отдаётся всё, что понадобится отчёту (Result ниже), — чтобы он читал результат
  # прогона, а не собирал конвейер заново и не расходился с ним в цифрах.
  class Pipeline
    # notices — замечания, которые стоит показать человеку, но которые не повод падать:
    # битая строка в данных, подозрительные единицы измерения, отсутствующая история.
    Result = Struct.new(:decisions, :state, :providers, :external, :operations, :config,
                        :notices, keyword_init: true)

    attr_reader :config, :notices

    def self.run(**options)
      new(**options).run
    end

    def initialize(queue_path:, providers_path:, config_path: nil, profile: nil,
                   history_path: nil, overrides_path: nil)
      @queue_path = queue_path
      @providers_path = providers_path
      @config_path = config_path || ScoringConfig::DEFAULT_PATH
      @profile = profile
      @history_path = history_path || ConversionStats::DEFAULT_PATH
      @overrides_path = overrides_path || ProviderOverrides::DEFAULT_PATH
      @notices = []
    end

    def run
      @config = ScoringConfig.load(@config_path, profile: @profile)
      note(config.weights_sum_warning)

      providers = load_providers
      operations = load_items(@queue_path) { |path| DataLoader.operations(path) }

      external = Router.routable(providers)
      raise InvalidInputError, "ни одного провайдера в пуле: некому маршрутизировать" if external.empty?

      note(targets_warning(external))

      stats = load_stats
      note("история не прочитана — конверсия считается по conversion_24h") if stats.empty?

      state = RoutingState.new(providers)
      decisions = build_router(external, stats).run(operations, state)

      Result.new(decisions: decisions, state: state, providers: providers, external: external,
                 operations: operations, config: config, notices: notices)
    end

    private

    def build_router(external, stats)
      Router.new(
        providers: external,
        scorer: SoftScorer.new(config: config, stats: stats),
        explain_top: config.explain_top_factors,
        simulator: build_simulator(stats)
      )
    end

    # Поля, которых нет в providers.json, приходят оверлеем из config/provider_overrides.yml.
    # Что именно дозаполнили — говорим вслух: в отчёте должно быть видно, где цифра из данных,
    # а где наша.
    def load_providers
      loaded = load_items(@providers_path) { |path| DataLoader.providers(path) }
      applied = ProviderOverrides.load(@overrides_path).apply(loaded)

      applied.filled.each { |name, fields| note("#{name}: своими полями дозаполнено #{fields.join(', ')}") }
      applied.providers
    end

    def load_stats
      options = config.options("conversion")

      ConversionStats.load(
        @history_path,
        amount_buckets: options.fetch("amount_buckets", ConversionStats::DEFAULT_BUCKETS),
        prior_strength: options.fetch("prior_strength", ConversionStats::DEFAULT_PRIOR_STRENGTH),
        slice_weights: options.fetch("slice_weights", ConversionStats::DEFAULT_SLICE_WEIGHTS),
        confidence_weighting: options.fetch("confidence_weighting", true)
      )
    end

    # Симулятор даёт simulated_result и latency_sec, а заодно события для штрафа за свежие
    # сбои. Выключенный — не ошибка: Router тогда работает по фиксированной выдержке.
    def build_simulator(stats)
      options = config.options("simulation")
      return nil unless options.fetch("enabled", true)

      ResultSimulator.new(
        stats: stats,
        seed: options.fetch("seed", ResultSimulator::DEFAULT_SEED),
        expired_share: options["expired_share"],
        latency_source: options.fetch("latency_source", "history")
      )
    end

    # Битая запись не роняет прогон — она попадает в notices, остальные обрабатываются.
    # А вот файл, из которого не вышло прочитать ничего, — уже повод остановиться.
    def load_items(path)
      loaded = yield(path)
      loaded.errors.each { |error| note("пропущено — #{path}: #{error}") }
      raise InvalidInputError, "в #{path} не оказалось ни одной пригодной записи" if loaded.items.empty?

      loaded.items
    end

    # Целевые доли задаются в процентах и должны давать около сотни. Если сумма вышла около
    # единицы, поле пришло долями (0.40 вместо 40) — и тогда каждый провайдер вечно выглядит
    # перебравшим свою цель, а фактор доли молча стоит на −1.
    def targets_warning(providers)
      total = providers.sum { |provider| provider.traffic_percentage.to_f }
      return nil if total.zero? || (total - 100).abs <= 1

      "traffic_percentage в сумме даёт #{format('%.2f', total)}, а ожидается ~100 — проверьте единицы"
    end

    def note(message)
      notices << message if message
    end
  end
end
