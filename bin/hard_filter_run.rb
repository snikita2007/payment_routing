#!/usr/bin/env ruby
# Черновой прогон очереди через hard-фильтры, без soft-целей.
#
# Полный конвейер живёт в bin/route.rb; этот скрипт остался как диагностика самих фильтров:
# из допущенных берётся первый по priority, никакой стратегии не изображается. Смысл — увидеть,
# как фильтры и состояние ведут себя на длинной очереди, не подмешивая скоринг.
#
# Выбор «первый по priority» больше не зашит в код: это профиль priority_only из
# config/scoring.yml, где весь вес отдан фактору priority. Заодно видно, что старое
# поведение выражается конфигом.
#
#   ruby bin/hard_filter_run.rb --queue data/operations_queue_10.json
#   ruby scripts/validate_10.rb out/hard_filter_dry_run.json

require "json"
require "optparse"
require "fileutils"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "routing"
require "routing/data_loader"

module HardFilterRun
  PROFILE = "priority_only".freeze

  Decision = Routing::Router::Decision

  module_function

  def run(queue_path:, providers_path:, out_path:)
    all_providers = load!(providers_path) { |path| Routing::DataLoader.providers(path) }
    operations = load!(queue_path) { |path| Routing::DataLoader.operations(path) }

    external = routable(all_providers)
    scorer = Routing::SoftScorer.new(config: Routing::ScoringConfig.load(profile: PROFILE))
    router = Routing::Router.new(providers: external, scorer: scorer)

    state = Routing::RoutingState.new(all_providers)
    decisions = router.run(operations, state)

    write_decisions(out_path, decisions)
    print_summary(all_providers, operations, decisions, state)
    decisions
  end

  def routable(providers)
    Routing::Router.routable(providers)
  end

  def load!(path)
    loaded = yield(path)
    loaded.errors.each { |error| warn "  пропущено — #{path}: #{error}" }
    abort "В #{path} не оказалось ни одной пригодной записи" if loaded.items.empty?
    loaded.items
  end

  def write_decisions(path, decisions)
    FileUtils.mkdir_p(File.dirname(path))
    payload = decisions.map do |decision|
      {
        "operation_id" => decision.operation.id,
        "selected_provider" => decision.provider ? decision.provider.name : Routing::SELF_PROVIDER,
        "attempts" => decision.attempts.map(&:to_h)
      }
    end
    File.write(path, JSON.pretty_generate(payload) + "\n")
  end

  # --- сводка -------------------------------------------------------------

  def print_summary(providers, operations, decisions, state)
    total = decisions.size
    puts "\nЗаявок обработано: #{total}"

    print_distribution(providers, decisions, total)
    print_skip_reasons(decisions)
    print_utilization(providers, state)

    fallbacks = decisions.count(&:fallback)
    puts "\nFallback на #{Routing::SELF_PROVIDER}: #{fallbacks} (#{pct(fallbacks, total)}%)"
    puts "Сумма очереди: #{operations.sum(&:amount).round} ₽"
  end

  def print_distribution(providers, decisions, total)
    counts = Hash.new(0)
    decisions.each do |decision|
      counts[decision.provider ? decision.provider.name : Routing::SELF_PROVIDER] += 1
    end

    puts "\nРаспределение (только каскад по priority, soft-цели выключены):"
    providers.each do |provider|
      count = counts[provider.name]
      target = provider.traffic_percentage
      target_text = target && target > 0 ? " при целевых #{fmt(target)}%" : ""
      puts format("  %-14s %4d  %5s%%%s", provider.name, count, pct(count, total), target_text)
    end
  end

  def print_skip_reasons(decisions)
    reasons = Hash.new(0)
    decisions.each do |decision|
      decision.attempts.select(&:skipped?).each { |attempt| reasons[attempt.reason] += 1 }
    end

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
      limit_text = limit == Float::INFINITY ? "без лимита" : limit.round.to_s
      util = limit == Float::INFINITY ? "—" : "#{pct(used, limit)}%"
      puts format("  %-14s %11s / %-11s %6s", provider.name, used.round, limit_text, util)
    end
  end

  def pct(part, whole)
    return "0.0" if whole.nil? || whole.zero? || whole == Float::INFINITY

    format("%.1f", part * 100.0 / whole)
  end

  def fmt(value)
    value == value.to_i ? value.to_i.to_s : format("%.1f", value)
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("..", __dir__)
  options = {
    queue: File.join(root, "data", "operations_queue_10.json"),
    providers: File.join(root, "data", "providers.json"),
    out: File.join(root, "out", "hard_filter_dry_run.json")
  }

  OptionParser.new do |parser|
    parser.banner = "Использование: ruby bin/hard_filter_run.rb [опции]"
    parser.on("--queue PATH", "очередь заявок") { |v| options[:queue] = v }
    parser.on("--providers PATH", "провайдеры") { |v| options[:providers] = v }
    parser.on("--out PATH", "куда положить решения") { |v| options[:out] = v }
  end.parse!

  begin
    HardFilterRun.run(
      queue_path: options[:queue],
      providers_path: options[:providers],
      out_path: options[:out]
    )
    puts "\nРешения записаны: #{options[:out]}"
  rescue Routing::InvalidInputError => e
    abort "Входные данные негодны: #{e.message}"
  end
end
