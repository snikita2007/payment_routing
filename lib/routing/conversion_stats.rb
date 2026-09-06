require_relative "errors"
require_relative "provider"

module Routing
  # Конверсия по data/operations_history.csv, срезами и со сглаживанием.
  #
  #   C_hist = 0.50·C_общая + 0.25·C_банк + 0.15·C_сумма + 0.10·C_card_brand
  #
  # Сырые доли брать нельзя: на провайдера в истории приходится 19–41 заявка, а на пару
  # провайдер+банк — от 2 до 10. Одна-две заявки в клетке дают 0% или 100%, и скорер начнёт
  # верить шуму. Поэтому каждый срез подтягивается к родительской ставке:
  #
  #   rate = (approved + α·parent) / (n + α)
  #
  # Родитель общего среза — глобальная ставка approve по всей истории, родитель остальных —
  # общая (уже сглаженная) ставка самого провайдера. Чем меньше в клетке данных, тем ближе
  # ответ к родителю; при n → ∞ он сходится к сырой доле.
  #
  # Срез без данных выбрасывается, а веса оставшихся перенормируются до суммы 1. Это не
  # теоретический случай: колонка card_brand пуста во всех 100 строках истории, и в очереди
  # card_brand тоже везде null — без перенормировки 0.10 веса просто исчезали бы из формулы.
  class ConversionStats
    DEFAULT_PATH = File.expand_path("../../data/operations_history.csv", __dir__).freeze

    APPROVED = "approved".freeze
    DEFAULT_BUCKETS = [5000, 50000, 100000].freeze
    DEFAULT_SLICE_WEIGHTS = {
      "overall" => 0.50,
      "bank" => 0.25,
      "amount" => 0.15,
      "card" => 0.10
    }.freeze
    DEFAULT_PRIOR_STRENGTH = 5
    # Во что верить, когда истории нет вовсе.
    NO_HISTORY_RATE = 0.5

    # Одна клетка: сколько заявок и сколько из них approved.
    Tally = Struct.new(:approved, :total) do
      def add(success)
        self.total += 1
        self.approved += 1 if success
        self
      end

      def rate
        total.zero? ? nil : approved.to_f / total
      end
    end

    # Слагаемое C_hist: срез, его сглаженная ставка, объём выборки и вес после перенормировки.
    Slice = Struct.new(:key, :label, :rate, :n, :weight, keyword_init: true)

    # Итог по одной заявке: значение и из чего оно сложилось — разбивка уходит в details.
    Estimate = Struct.new(:value, :slices, :source, keyword_init: true) do
      def to_s
        return format("%.3f (%s)", value, source) if slices.empty?

        parts = slices.map do |slice|
          format("%s %.2f×%.2f (n=%d)", slice.label, slice.weight, slice.rate, slice.n)
        end
        format("%.3f = %s", value, parts.join(" + "))
      end
    end

    attr_reader :amount_buckets, :prior_strength, :slice_weights, :confidence_weighting, :rows, :errors

    def self.load(path = DEFAULT_PATH, amount_buckets: DEFAULT_BUCKETS,
                  prior_strength: DEFAULT_PRIOR_STRENGTH, slice_weights: DEFAULT_SLICE_WEIGHTS,
                  confidence_weighting: true)
      new(
        read_rows(path),
        amount_buckets: amount_buckets,
        prior_strength: prior_strength,
        slice_weights: slice_weights,
        confidence_weighting: confidence_weighting
      )
    end

    # История не обязательна: без неё скорер работает на заявленной конверсии.
    def self.empty(**options)
      new([], **options)
    end

    # Разбор вручную, без гема csv: с Ruby 3.4 он больше не default gem и под bundler
    # не грузится, а в файле нет ни кавычек, ни запятых внутри полей.
    def self.read_rows(path)
      return [] if path.nil? || !File.file?(path)

      lines = File.readlines(path, chomp: true).reject { |line| line.strip.empty? }
      return [] if lines.empty?

      header = split_line(lines.shift).map { |name| name.strip.downcase }
      lines.filter_map do |line|
        values = split_line(line)
        next if values.size != header.size

        header.zip(values).to_h
      end
    end

    def self.split_line(line)
      line.sub(/\r\z/, "").split(",", -1)
    end

    def initialize(rows, amount_buckets: DEFAULT_BUCKETS, prior_strength: DEFAULT_PRIOR_STRENGTH,
                   slice_weights: DEFAULT_SLICE_WEIGHTS, confidence_weighting: true)
      @amount_buckets = Array(amount_buckets).map(&:to_f).sort
      @prior_strength = prior_strength.to_f
      # Нулевая сила сглаживания оставляет 0/0 на пустой клетке, а отрицательная — бессмысленна.
      if @prior_strength <= 0
        raise InvalidInputError, "prior_strength должен быть больше нуля, получено #{prior_strength.inspect}"
      end

      @slice_weights = normalize_weights(slice_weights)
      @confidence_weighting = confidence_weighting
      @errors = []
      @rows = Array(rows)
      build_tallies
    end

    def empty?
      @global.total.zero?
    end

    def providers
      @by_provider.keys
    end

    def sample_size(provider)
      tally_for(@by_provider, name_of(provider)).total
    end

    # Сырая доля approve по всей истории — точка отсчёта для сглаживания.
    def global_rate
      @global.rate || NO_HISTORY_RATE
    end

    # Сглаженная общая ставка провайдера. Незнакомый провайдер получает глобальную.
    def overall_rate(provider)
      smooth(tally_for(@by_provider, name_of(provider)), global_rate)
    end

    # Медиана времени успешных заявок — запасной источник для фактора скорости,
    # когда в providers.json нет avg_latency_sec. Просроченные заявки в выборку не берём:
    # их latency на порядок больше и сдвинула бы медиану.
    def median_latency(provider)
      samples = @latency[name_of(provider)]
      return nil if samples.nil? || samples.empty?

      sorted = samples.sort
      middle = sorted.size / 2
      sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    # C_hist для конкретной заявки.
    def estimate(provider, bank: nil, amount: nil, card_brand: nil)
      name = name_of(provider)
      parent = overall_rate(name)

      candidates = [
        slice("overall", "общая", tally_for(@by_provider, name), global_rate),
        slice("bank", bank_label(bank), bank_tally(name, bank), parent),
        slice("amount", amount_label(amount), amount_tally(name, amount), parent),
        slice("card", card_label(card_brand), card_tally(name, card_brand), parent)
      ].compact

      return Estimate.new(value: parent, slices: [], source: source_without_slices(name)) if candidates.empty?

      weighted(candidates)
    end

    private

    def build_tallies
      @global = Tally.new(0, 0)
      @by_provider = new_table
      @by_bank = new_table
      @by_amount = new_table
      @by_card = new_table
      @latency = Hash.new { |hash, key| hash[key] = [] }

      rows.each_with_index { |row, index| absorb(row, index) }
    end

    def absorb(row, index)
      name = value_of(row, "payment_system", "provider", "provider_name")
      status = value_of(row, "status", "result")

      if name.to_s.strip.empty? || status.to_s.strip.empty?
        errors << "строка #{index + 2}: нет payment_system или status"
        return
      end

      success = status.strip.downcase == APPROVED
      bank = normalize(value_of(row, "bank", "bank_name"))
      card = normalize(value_of(row, "card_brand"))
      amount = to_amount(value_of(row, "amount", "sum"))

      @global.add(success)
      tally_for(@by_provider, name).add(success)
      tally_for(@by_bank, [name, bank]).add(success) unless bank.empty?
      tally_for(@by_amount, [name, bucket_index(amount)]).add(success) unless amount.nil?
      tally_for(@by_card, [name, card]).add(success) unless card.empty?

      latency = to_amount(value_of(row, "latency_sec", "latency"))
      @latency[name] << latency if success && latency
    end

    # Срез участвует в формуле, только если в нём есть хоть одна заявка.
    #
    # Номинального веса мало: клетка payflow×sberbank держится на трёх строках, а вес
    # у неё тот же 0.25, что у клетки на сорока. Поэтому вес умножается на долю уверенности
    # n/(n+α) — тонкая клетка говорит тише, пустая замолкает сама, и отдельная ветка
    # «выбросить срез с n = 0» становится частным случаем, а не исключением.
    def slice(key, label, tally, parent)
      return nil if tally.total.zero?

      weight = slice_weights.fetch(key, 0.0)
      weight *= tally.total / (tally.total + prior_strength) if confidence_weighting

      Slice.new(key: key, label: label, rate: smooth(tally, parent), n: tally.total, weight: weight)
    end

    # Перенормировка: выпавшие срезы не должны утаскивать свой вес в никуда.
    def weighted(candidates)
      present = candidates.reject { |item| item.weight.zero? }
      present = candidates if present.empty?

      total = present.sum(&:weight)
      return Estimate.new(value: present.first.rate, slices: present, source: "history") if total.zero?

      present.each { |item| item.weight = item.weight / total }
      value = present.sum { |item| item.weight * item.rate }

      Estimate.new(value: value, slices: present, source: "history")
    end

    def smooth(tally, parent)
      (tally.approved + prior_strength * parent) / (tally.total + prior_strength)
    end

    def bank_tally(name, bank)
      key = normalize(bank)
      key.empty? ? Tally.new(0, 0) : tally_for(@by_bank, [name, key])
    end

    def amount_tally(name, amount)
      value = to_amount(amount)
      value.nil? ? Tally.new(0, 0) : tally_for(@by_amount, [name, bucket_index(value)])
    end

    def card_tally(name, card_brand)
      key = normalize(card_brand)
      key.empty? ? Tally.new(0, 0) : tally_for(@by_card, [name, key])
    end

    def bank_label(bank)
      key = normalize(bank)
      key.empty? ? "банк" : "банк #{key}"
    end

    def card_label(card_brand)
      key = normalize(card_brand)
      key.empty? ? "card_brand" : "card #{key}"
    end

    # Границы включительные сверху: 5000 попадает в первый бакет, 5001 — во второй.
    def bucket_index(amount)
      amount_buckets.count { |edge| amount > edge }
    end

    def amount_label(amount)
      value = to_amount(amount)
      return "сумма" if value.nil?

      index = bucket_index(value)
      low = index.zero? ? nil : amount_buckets[index - 1]
      high = amount_buckets[index]

      return "сумма ≤#{fmt(high)}" if low.nil?
      return "сумма >#{fmt(low)}" if high.nil?

      "сумма #{fmt(low)}–#{fmt(high)}"
    end

    def source_without_slices(name)
      empty? ? "нет истории" : "нет данных по #{name}"
    end

    def new_table
      Hash.new { |hash, key| hash[key] = Tally.new(0, 0) }
    end

    def tally_for(table, key)
      table[key]
    end

    def name_of(provider)
      provider.is_a?(Provider) ? provider.name : provider.to_s
    end

    def value_of(row, *keys)
      keys.each do |key|
        value = row[key]
        return value unless value.nil?
      end
      nil
    end

    def normalize(value)
      Provider.normalize_bank(value)
    end

    def to_amount(value)
      return value if value.is_a?(Numeric)

      text = value.to_s.strip
      return nil if text.empty?

      Float(text)
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_weights(weights)
      (weights || {}).to_h { |key, value| [key.to_s, value.to_f] }
    end

    def fmt(value)
      value == value.to_i ? value.to_i.to_s : format("%.0f", value)
    end
  end
end
