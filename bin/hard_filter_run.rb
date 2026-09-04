#!/usr/bin/env ruby
# Черновой прогон очереди через hard-фильтры.
#
# Скорера ещё нет, поэтому из допущенных провайдеров берётся первый по priority —
# ЗАГЛУШКА до SoftScorer, никакой стратегии здесь не изображается. Смысл прогона в другом:
# посмотреть, как фильтры и состояние ведут себя на длинной очереди.
#
#   ruby bin/hard_filter_run.rb --queue data/operations_queue_test.json

require "json"
require "optparse"
require "fileutils"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "routing"
require "routing/data_loader"

module HardFilterRun
  FALLBACK_REASON = "fallback_self_provider".freeze
  ONLY_ELIGIBLE = "only_eligible_provider".freeze
  BY_PRIORITY = "first_by_priority".freeze

  # Сколько заявка висит в работе, прежде чем освободить in-progress.
  # Настоящую длительность даст симулятор результата вместе со скорером.
  HOLD_SEC = 45

  Decision = Struct.new(:operation, :provider, :attempts, :fallback, keyword_init: true)

  module_function

  def run(queue_path:, providers_path:, out_path:)
    all_providers = load!(providers_path) { |path| Routing::DataLoader.providers(path) }
    operations = load!(queue_path) { |path| Routing::DataLoader.operations(path) }

    # Self-provider не участвует в общем пуле: он последняя инстанция, а не конкурент.
    external = all_providers.reject { |provider| provider.name == Routing::SELF_PROVIDER }

    state = Routing::RoutingState.new(all_providers)
    in_flight = []
    decisions = operations.map do |operation|
      release_finished(state, in_flight, operation.created_at || state.now)
      route(external, operation, state, in_flight)
    end

    write_decisions(out_path, decisions)
    print_summary(all_providers, operations, decisions, state)
    decisions
  end

  # Заявки не висят в работе вечно: к моменту следующей операции часть уже завершилась
  # и освободила лимиты. Без этого in-progress только растёт и съедает весь пул.
  def release_finished(state, in_flight, now)
    in_flight.reject! do |entry|
      next false if entry[:until] > now

      state.release_in_progress(entry[:provider], entry[:amount])
      true
    end
  end

  def load!(path)
    loaded = yield(path)
    loaded.errors.each { |error| warn "  пропущено — #{path}: #{error}" }
    abort "В #{path} не оказалось ни одной пригодной записи" if loaded.items.empty?
    loaded.items
  end

  def route(providers, operation, state, in_flight)
    result = Routing::HardConstraints.eligible(providers, operation, state)
    attempts = result.rejections.dup

    if result.empty?
      # Пул пуст — заявка уходит self-provider'у, hard-ограничения при этом не ослабляются.
      attempts << Routing::Attempt.selected(Routing::SELF_PROVIDER, FALLBACK_REASON,
                                            "все внешние провайдеры исключены")
      apply_state(state, Routing::SELF_PROVIDER, operation, in_flight)
      return Decision.new(operation: operation, provider: nil, attempts: attempts, fallback: true)
    end

    chosen = result.eligible.min_by { |provider| provider.priority || Float::INFINITY }
    reason = result.eligible.size == 1 ? ONLY_ELIGIBLE : BY_PRIORITY
    details = "priority #{chosen.priority}, допущено #{result.eligible.size} из #{providers.size}"
    attempts << Routing::Attempt.selected(chosen.name, reason, details)

    apply_state(state, chosen, operation, in_flight)
    Decision.new(operation: operation, provider: chosen, attempts: attempts, fallback: false)
  end

  # Состояние двигается после каждой заявки: следующая уже видит новый оборот и загрузку.
  # Отдельный StateUpdater появится вместе со скорером — пока это его минимальная версия.
  def apply_state(state, provider, operation, in_flight)
    at = operation.created_at || state.now
    state.record_request(provider, at: at)
    state.add_in_progress(provider, operation.amount)
    state.add_daily_amount(provider, operation.amount)
    in_flight << { provider: provider, amount: operation.amount, until: at + HOLD_SEC }
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

    puts "\nРаспределение (заглушка по priority, не стратегия):"
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
    queue: File.join(root, "data", "operations_queue_test.json"),
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
