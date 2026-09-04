#!/usr/bin/env ruby
# Генератор синтетических данных в data/.
#
# Настоящие providers.json / operations_queue_test.json придут от организаторов и лягут
# на то же место. Это заглушка, чтобы было на чём гонять конвейер, и она детерминирована:
# один и тот же --seed даёт один и тот же набор файлов.
#
#   ruby tools/generate_data.rb --seed 42 --queue-size 200 --out data

require "json"
require "csv"
require "time"
require "fileutils"
require "optparse"

module DataGenerator
  BANKS = %w[sber tinkoff alfa vtb raiffeisen gazprombank ozon yandex].freeze

  # Банки, которых нет ни в одном белом списке — под проверку bank_not_in_list.
  RARE_BANKS = %w[uralsib pochta mts].freeze

  DAY = "2026-07-30".freeze

  # Провайдеры подобраны так, чтобы на длинной очереди срабатывала каждая hard-проверка:
  # если данные слепы к части фильтров, прогон ничего не доказывает.
  PROVIDERS = [
    {
      "name" => "vipay",
      "status" => "active",
      "traffic_percentage" => 35,
      "volume_share_pct" => 45,
      "priority" => 1,
      "limit_amount_min" => 1_000,
      "limit_amount_max" => 150_000,
      "daily_amount_limit" => 5_000_000,
      "daily_approved_amount" => 3_215_000,
      "daily_turnover_max" => 5_000_000,
      "in_progress_count_limit" => 40,
      "in_progress_count" => 12,
      "in_progress_amount_limit" => 1_500_000,
      "in_progress_amount" => 240_000,
      "requests_per_minute_limit" => 15,
      "banks" => %w[sber tinkoff alfa raiffeisen ozon],
      "exclude_banks" => [],
      "available_requisites" => 8,
      "provider_margin_pct" => 1.5
    },
    {
      "name" => "payflow",
      "status" => "active",
      "traffic_percentage" => 30,
      "volume_share_pct" => 20,
      "priority" => 2,
      "limit_amount_min" => 500,
      "limit_amount_max" => 50_000,
      "daily_amount_limit" => 4_000_000,
      "daily_approved_amount" => 1_100_000,
      "daily_turnover_min" => 2_000_000,
      "in_progress_count_limit" => 30,
      "in_progress_count" => 5,
      "in_progress_amount_limit" => 250_000,
      "in_progress_amount" => 80_000,
      "requests_per_minute_limit" => 7,
      "exclude_banks" => %w[vtb],
      "available_requisites" => 5,
      "provider_margin_pct" => 2.0
    },
    {
      "name" => "quickpay",
      "status" => "active",
      "traffic_percentage" => 20,
      "volume_share_pct" => 25,
      "priority" => 3,
      "limit_amount_min" => 5_000,
      "limit_amount_max" => 800_000,
      "daily_amount_limit" => 9_000_000,
      "daily_approved_amount" => 900_000,
      "in_progress_count_limit" => 25,
      "in_progress_count" => 3,
      "in_progress_amount_limit" => 2_000_000,
      "in_progress_amount" => 150_000,
      "requests_per_minute_limit" => 20,
      "available_requisites" => 12,
      "provider_margin_pct" => 2.9
    },
    {
      "name" => "fastline",
      "status" => "active",
      "traffic_percentage" => 15,
      "volume_share_pct" => 10,
      "priority" => 4,
      "limit_amount_min" => 500,
      "limit_amount_max" => 120_000,
      "daily_amount_limit" => 2_500_000,
      "daily_approved_amount" => 400_000,
      "in_progress_count_limit" => 6,
      "in_progress_count" => 4,
      "in_progress_amount_limit" => 300_000,
      "in_progress_amount" => 90_000,
      "requests_per_minute_limit" => 5,
      "banks" => %w[sber vtb gazprombank yandex],
      "available_requisites" => 2,
      "provider_margin_pct" => 1.8
    },
    {
      # На момент снимка все терминалы заняты — проверка реквизитов.
      "name" => "ratepay",
      "status" => "active",
      "traffic_percentage" => 0,
      "volume_share_pct" => 0,
      "priority" => 6,
      "limit_amount_min" => 500,
      "limit_amount_max" => 300_000,
      "daily_amount_limit" => 3_000_000,
      "daily_approved_amount" => 120_000,
      "available_requisites" => 0,
      "provider_margin_pct" => 1.1
    },
    {
      "name" => "oldgate",
      "status" => "disabled",
      "traffic_percentage" => 0,
      "volume_share_pct" => 0,
      "priority" => 5,
      "limit_amount_min" => 100,
      "limit_amount_max" => 900_000,
      "daily_amount_limit" => 1_000_000,
      "daily_approved_amount" => 0,
      "available_requisites" => 4,
      "provider_margin_pct" => 1.2
    },
    {
      # Self-provider: последняя инстанция, ограничений нет, целевой доли тоже.
      "name" => "spacepayments",
      "status" => "active",
      "traffic_percentage" => 0,
      "volume_share_pct" => 0,
      "priority" => 99,
      "limit_amount_min" => 100,
      "daily_approved_amount" => 0,
      "provider_margin_pct" => 0.5
    }
  ].freeze

  # Доля успеха для генерации истории. conversion_24h потом считается из самой истории,
  # а не берётся отсюда: иначе метрика провайдера и его же история противоречат друг другу.
  TRUE_APPROVE_RATE = {
    "vipay" => 0.87,
    "payflow" => 0.79,
    "quickpay" => 0.71,
    "fastline" => 0.83,
    "oldgate" => 0.40,
    "spacepayments" => 0.93
  }.freeze

  module_function

  def generate(seed:, queue_size:, out_dir:)
    rng = Random.new(seed)
    FileUtils.mkdir_p(out_dir)

    history = build_history(rng)
    providers = build_providers(history)

    write_json(File.join(out_dir, "providers.json"), providers)
    write_history(File.join(out_dir, "operations_history.csv"), history)
    write_json(File.join(out_dir, "operations_queue.json"), build_queue(rng, 10, "op"))
    write_json(File.join(out_dir, "operations_queue_test.json"),
               build_queue(rng, queue_size, "opt"))

    { providers: providers.size, history: history.size, queue: queue_size }
  end

  # --- провайдеры ---------------------------------------------------------

  def build_providers(history)
    PROVIDERS.map do |provider|
      provider.merge("conversion_24h" => conversion_from(history, provider["name"]))
    end
  end

  def conversion_from(history, provider_name)
    rows = history.select { |row| row["provider"] == provider_name }
    return TRUE_APPROVE_RATE.fetch(provider_name, 0.8) if rows.empty?

    approved = rows.count { |row| row["result"] == "approved" }
    (approved.to_f / rows.size).round(3)
  end

  # --- история ------------------------------------------------------------

  def build_history(rng, size = 100)
    routable = PROVIDERS.reject { |p| p["traffic_percentage"].to_i.zero? }
    base = Time.parse("#{DAY}T00:00:00+03:00") - 24 * 3600

    Array.new(size) do |index|
      provider = pick_by_traffic(routable, rng)
      amount = log_normal_amount(rng)
      result = simulate_result(TRUE_APPROVE_RATE.fetch(provider["name"]), rng)

      {
        "operation_id" => format("hist_%03d", index + 1),
        "created_at" => (base + rng.rand(24 * 3600)).iso8601,
        "amount" => amount,
        "bank" => BANKS[rng.rand(BANKS.size)],
        "provider" => provider["name"],
        "decision" => "selected",
        "reason" => "strategy_share_by_count",
        "result" => result,
        "latency_sec" => rng.rand(3..90)
      }
    end.sort_by { |row| row["created_at"] }
  end

  def pick_by_traffic(providers, rng)
    total = providers.sum { |p| p["traffic_percentage"] }
    point = rng.rand * total
    cursor = 0.0

    providers.each do |provider|
      cursor += provider["traffic_percentage"]
      return provider if point < cursor
    end
    providers.last
  end

  def simulate_result(approve_rate, rng)
    roll = rng.rand
    return "approved" if roll < approve_rate
    # Небольшая часть неуспехов — таймауты, а не отказы.
    roll < approve_rate + (1 - approve_rate) * 0.75 ? "rejected" : "expired"
  end

  # --- очередь ------------------------------------------------------------

  def build_queue(rng, size, prefix)
    clock = Time.parse("#{DAY}T09:00:00+03:00")
    operations = []

    while operations.size < size
      # Заявки идут всплесками: несколько штук в одну-две секунды, потом пауза.
      # Без сгущения скользящее окно RPM никогда не сработает.
      burst = rng.rand(1..6)
      burst.times do
        break if operations.size >= size

        operations << build_operation(rng, "#{prefix}_#{format('%04d', operations.size + 1)}", clock)
        clock += rng.rand(0..2)
      end
      clock += rng.rand(5..40)
    end

    operations
  end

  def build_operation(rng, id, at)
    {
      "operation_id" => id,
      "created_at" => at.iso8601,
      "amount" => log_normal_amount(rng),
      "currency" => "RUB",
      "bank" => pick_bank(rng),
      "merchant_margin_pct" => pick_merchant_margin(rng)
    }
  end

  # Много мелких чеков, длинный хвост крупных: так задеваются обе границы
  # limit_amount_min/max, а не только одна.
  def log_normal_amount(rng)
    value = Math.exp(9.4 + rng.rand * 2.4 - 1.2) * (0.6 + rng.rand)
    amount = value.round(-2).to_i
    amount = 300 if amount < 300
    amount = 950_000 if amount > 950_000
    amount
  end

  def pick_bank(rng)
    roll = rng.rand
    # ~2% заявок приходят без банка: он ещё не определён на момент роутинга.
    return nil if roll < 0.02
    # ~8% заявок из банков, которых нет ни в одном белом списке.
    return RARE_BANKS[rng.rand(RARE_BANKS.size)] if roll < 0.10

    BANKS[rng.rand(BANKS.size)]
  end

  # Часть мерчантов работает на тонкой марже — под проверку negative_margin.
  def pick_merchant_margin(rng)
    return (1.0 + rng.rand * 0.6).round(2) if rng.rand < 0.2

    (2.4 + rng.rand * 1.1).round(2)
  end

  # --- запись -------------------------------------------------------------

  def write_json(path, data)
    File.write(path, JSON.pretty_generate(data) + "\n")
  end

  def write_history(path, rows)
    headers = rows.first.keys
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { seed: 42, queue_size: 200, out: File.expand_path("../data", __dir__) }

  OptionParser.new do |parser|
    parser.banner = "Использование: ruby tools/generate_data.rb [опции]"
    parser.on("--seed N", Integer, "сид генератора (по умолчанию 42)") { |v| options[:seed] = v }
    parser.on("--queue-size N", Integer, "заявок в operations_queue_test.json") { |v| options[:queue_size] = v }
    parser.on("--out DIR", "куда писать (по умолчанию data/)") { |v| options[:out] = v }
  end.parse!

  stats = DataGenerator.generate(
    seed: options[:seed],
    queue_size: options[:queue_size],
    out_dir: options[:out]
  )

  puts "Записано в #{options[:out]}: провайдеров #{stats[:providers]}, " \
       "история #{stats[:history]} строк, тестовая очередь #{stats[:queue]} заявок (сид #{options[:seed]})"
end
