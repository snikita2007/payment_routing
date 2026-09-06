#!/usr/bin/env ruby
# Прогон очереди через полный конвейер: hard-фильтры → soft-скоринг → решение.
#
#   ruby bin/route.rb
#   ruby bin/route.rb --profile declared --out out/run_declared.json
#   ruby scripts/validate_10.rb out/routing_decisions.json
#
# Веса и параметры скоринга — в config/scoring.yml, поля, которых нет в providers.json, —
# в config/provider_overrides.yml. Здесь только склейка и печать сводки.

require "json"
require "optparse"
require "fileutils"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "routing"
require "routing/data_loader"

module Route
  ROOT = File.expand_path("..", __dir__)

  module_function

  def run(queue_path:, providers_path:, out_path:, config_path: nil, profile: nil,
          history_path: nil, overrides_path: nil, quiet: false)
    config = Routing::ScoringConfig.load(config_path || Routing::ScoringConfig::DEFAULT_PATH,
                                         profile: profile)
    notice(config.weights_sum_warning)

    providers = load_providers(providers_path, overrides_path)
    operations = load!(queue_path) { |path| Routing::DataLoader.operations(path) }

    external = Routing::Router.routable(providers)
    abort "Ни одного провайдера в пуле: некому маршрутизировать" if external.empty?
    notice(targets_warning(external))

    stats = build_stats(history_path, config)
    notice("история не прочитана — конверсия считается по conversion_24h") if stats.empty?

    scorer = Routing::SoftScorer.new(config: config, stats: stats)
    router = Routing::Router.new(providers: external, scorer: scorer,
                                 explain_top: config.explain_top_factors,
                                 simulator: build_simulator(config, stats))

    state = Routing::RoutingState.new(providers)
    decisions = router.run(operations, state)

    write_decisions(out_path, decisions)
    print_summary(config, providers, external, operations, decisions, state) unless quiet
    decisions
  end

  def load_providers(providers_path, overrides_path)
    loaded = load!(providers_path) { |path| Routing::DataLoader.providers(path) }
    path = overrides_path || Routing::ProviderOverrides::DEFAULT_PATH
    applied = Routing::ProviderOverrides.load(path).apply(loaded)

    applied.filled.each do |name, fields|
      notice("#{name}: своими полями дозаполнено #{fields.join(', ')}")
    end

    applied.providers
  end

  def build_stats(history_path, config)
    options = config.options("conversion")

    Routing::ConversionStats.load(
      history_path || Routing::ConversionStats::DEFAULT_PATH,
      amount_buckets: options.fetch("amount_buckets", Routing::ConversionStats::DEFAULT_BUCKETS),
      prior_strength: options.fetch("prior_strength", Routing::ConversionStats::DEFAULT_PRIOR_STRENGTH),
      slice_weights: options.fetch("slice_weights", Routing::ConversionStats::DEFAULT_SLICE_WEIGHTS),
      confidence_weighting: options.fetch("confidence_weighting", true)
    )
  end

  # Симулятор даёт simulated_result и latency_sec, а заодно события для штрафа
  # за свежие сбои. Выключенный — не ошибка: Router тогда работает по фиксированной выдержке.
  def build_simulator(config, stats)
    options = config.options("simulation")
    return nil unless options.fetch("enabled", true)

    Routing::ResultSimulator.new(
      stats: stats,
      seed: options.fetch("seed", Routing::ResultSimulator::DEFAULT_SEED),
      expired_share: options["expired_share"],
      latency_source: options.fetch("latency_source", "history")
    )
  end

  def load!(path)
    loaded = yield(path)
    loaded.errors.each { |error| notice("пропущено — #{path}: #{error}") }
    abort "В #{path} не оказалось ни одной пригодной записи" if loaded.items.empty?
    loaded.items
  end

  # Целевые доли задаются в процентах и должны давать около сотни. Если сумма вышла
  # около единицы, поле пришло долями (0.40 вместо 40) — и тогда каждый провайдер вечно
  # выглядит перебравшим свою цель, а фактор доли молча стоит на −1.
  def targets_warning(providers)
    total = providers.sum { |provider| provider.traffic_percentage.to_f }
    return nil if total.zero? || (total - 100).abs <= 1

    "traffic_percentage в сумме даёт #{format('%.2f', total)}, а ожидается ~100 — проверьте единицы"
  end

  def notice(message)
    warn("  #{message}") if message
  end

  def write_decisions(path, decisions)
    FileUtils.mkdir_p(File.dirname(path))
    payload = decisions.map do |decision|
      item = {
        "operation_id" => decision.operation.id,
        "selected_provider" => decision.provider ? decision.provider.name : Routing::SELF_PROVIDER,
        "attempts" => decision.attempts.map(&:to_h)
      }

      if decision.outcome
        item["simulated_result"] = decision.outcome.status
        item["latency_sec"] = decision.outcome.latency_sec
      end

      item
    end
    File.write(path, JSON.pretty_generate(payload) + "\n")
  end

  # --- сводка -------------------------------------------------------------

  def print_summary(config, providers, external, operations, decisions, state)
    puts "\nПрофиль: #{config.profile_name}   #{weights_line(config)}"
    puts "Заявок обработано: #{decisions.size}"

    print_distribution(external, decisions, state)
    print_outcomes(decisions)
    print_skip_reasons(decisions)
    print_utilization(providers, state)

    fallbacks = decisions.count(&:fallback)
    puts "\nFallback на #{Routing::SELF_PROVIDER}: #{fallbacks} (#{pct(fallbacks, decisions.size)}%)"
    puts "Сумма очереди: #{fmt_money(operations.sum(&:amount))} ₽"
  end

  def weights_line(config)
    config.weights.reject { |_, value| value.to_f.zero? }
          .map { |key, value| "#{key} #{format('%.2f', value)}" }
          .join("  ")
  end

  def print_distribution(external, decisions, state)
    puts "\nРаспределение против целевого:"
    puts format("  %-14s %5s %8s %8s %8s   %8s %8s %8s",
                "провайдер", "шт", "факт%", "цель%", "Δ", "объём%", "цель%", "Δ")

    external.each do |provider|
      puts format("  %-14s %5d %7.1f%% %s   %7.1f%% %s",
                  provider.name, state.routed_count(provider),
                  state.count_share_pct(provider),
                  target_columns(state.count_share_pct(provider), provider.traffic_percentage),
                  state.volume_share_pct(provider),
                  target_columns(state.volume_share_pct(provider), provider.volume_share_pct))
    end

    puts format("  %-14s %5d", "итого", state.total_routed_count)
    print_soft_selection(decisions)
  end

  # Незаданная цель и цель, равная нулю, — разные вещи, и в сводке это должно быть видно:
  # иначе отклонение от несуществующей цели читается как реальный перебор.
  def target_columns(actual, target)
    return format("%8s %7s", "—", "—") if target.nil?

    format("%7.1f%% %+7.1f", target.to_f, actual - target.to_f)
  end

  # Сколько решений реально принял скорер, а сколько было предопределено фильтрами.
  # Без этой строки распределение читается как заслуга скоринга, хотя часть заявок
  # выбора не имела вовсе.
  def print_soft_selection(decisions)
    contested = decisions.count { |decision| decision.ranked.size > 1 }
    forced = decisions.count { |decision| decision.ranked.size == 1 }
    puts "\n  скорер выбирал: #{contested}, предопределено фильтрами: #{forced}, " \
         "fallback: #{decisions.count(&:fallback)}"
  end

  def print_outcomes(decisions)
    outcomes = decisions.map(&:outcome).compact
    return if outcomes.empty?

    puts "\nСимулированные исходы:"
    Routing::ResultSimulator::STATUSES.each do |status|
      matching = outcomes.select { |outcome| outcome.status == status }
      next if matching.empty?

      latency = matching.sum(&:latency_sec).fdiv(matching.size)
      puts format("  %-10s %3d  %5s%%   средняя задержка %d с",
                  status, matching.size, pct(matching.size, outcomes.size), latency.round)
    end

    by_provider = Hash.new { |hash, key| hash[key] = [0, 0] }
    decisions.each do |decision|
      next unless decision.outcome

      name = decision.provider ? decision.provider.name : Routing::SELF_PROVIDER
      by_provider[name][0] += 1
      by_provider[name][1] += 1 if decision.outcome.failure?
    end

    failures = by_provider.map { |name, (total, bad)| "#{name} #{bad}/#{total}" }
    puts "  сбоев по провайдерам: #{failures.join(', ')}"
  end

  def print_skip_reasons(decisions)
    reasons = Hash.new(0)
    decisions.each do |decision|
      decision.attempts.select(&:skipped?).each { |attempt| reasons[attempt.reason] += 1 }
    end
    return if reasons.empty?

    puts "\nПричины отсева:"
    reasons.sort_by { |_, count| -count }.each do |reason, count|
      puts format("  %-26s %d", reason, count)
    end
  end

  def print_utilization(providers, state)
    puts "\nЗагрузка дневных лимитов на конец прогона:"
    providers.each do |provider|
      limit = provider.daily_amount_limit
      used = state.daily_approved_amount(provider)
      limit_text = limit == Float::INFINITY ? "без лимита" : fmt_money(limit)
      util = limit == Float::INFINITY ? "—" : "#{pct(used, limit)}%"
      puts format("  %-14s %13s / %-13s %7s", provider.name, fmt_money(used), limit_text, util)
    end
  end

  def pct(part, whole)
    return "0.0" if whole.nil? || whole.zero? || whole == Float::INFINITY

    format("%.1f", part * 100.0 / whole)
  end

  def fmt_money(value)
    value.round.to_s.reverse.scan(/\d{1,3}/).join(" ").reverse
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    queue: File.join(Route::ROOT, "data", "operations_queue_10.json"),
    providers: File.join(Route::ROOT, "data", "providers.json"),
    out: File.join(Route::ROOT, "out", "routing_decisions.json"),
    config: nil,
    profile: nil,
    history: nil,
    overrides: nil
  }

  OptionParser.new do |parser|
    parser.banner = "Использование: ruby bin/route.rb [опции]"
    parser.on("--queue PATH", "очередь заявок") { |v| options[:queue] = v }
    parser.on("--providers PATH", "провайдеры") { |v| options[:providers] = v }
    parser.on("--config PATH", "настройки скоринга") { |v| options[:config] = v }
    parser.on("--profile NAME", "профиль весов из конфига") { |v| options[:profile] = v }
    parser.on("--history PATH", "история операций") { |v| options[:history] = v }
    parser.on("--overrides PATH", "оверлей полей провайдеров") { |v| options[:overrides] = v }
    parser.on("--out PATH", "куда положить решения") { |v| options[:out] = v }
  end.parse!

  begin
    Route.run(
      queue_path: options[:queue],
      providers_path: options[:providers],
      out_path: options[:out],
      config_path: options[:config],
      profile: options[:profile],
      history_path: options[:history],
      overrides_path: options[:overrides]
    )
    puts "\nРешения записаны: #{options[:out]}"
  rescue Routing::InvalidInputError => e
    abort "Входные данные негодны: #{e.message}"
  end
end
