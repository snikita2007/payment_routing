require_relative "factors"
require_relative "scoring_config"

module Routing
  # Ранжирование провайдеров, уже прошедших hard-фильтры.
  #
  #   Score = Σ вес_фактора · значение_фактора
  #
  # Скорер ничего не решает про допуск: перевесить hard-ограничение скором нельзя,
  # сюда приходит только то, что уже прошло. Состояние он не меняет — двигает его Router
  # после того, как выбор сделан.
  #
  # Список факторов и их веса берутся из конфига. Фактор с нулевым весом не считается вовсе:
  # нулевой вес — это «правило выключено», а не «правило посчитали и умножили на ноль».
  class SoftScorer
    # До какого знака сравниваем скоры. Без округления два арифметически равных числа
    # разойдутся в 16-м знаке, и порядок начнёт зависеть от порядка сложения.
    ROUND_DP = 6

    TIE_BREAKS = %w[priority_asc conversion_desc name_asc input_order].freeze

    # Одно слагаемое итогового скора.
    Contribution = Struct.new(:factor, :value, :weight, :contribution, :explain, keyword_init: true)

    Scored = Struct.new(:provider, :score, :contributions, keyword_init: true) do
      def name
        provider.name
      end

      # Факторы, сильнее прочих повлиявшие на итог, — по модулю вклада.
      def top(count)
        contributions.reject { |item| item.contribution.zero? }
                     .sort_by { |item| -item.contribution.abs }
                     .first(count)
      end

      def breakdown(count)
        leading = top(count)
        return format("score %.3f", score) if leading.empty?

        parts = leading.map do |item|
          format("%s %.2f×%.2f", item.factor, item.weight, item.value)
        end
        rest = contributions.count { |item| !item.contribution.zero? } - leading.size
        tail = rest.positive? ? " (+#{rest})" : ""

        format("score %.3f = %s%s", score, parts.join(" + "), tail)
      end

      # Строка для details в attempts: из чего сложился скор и что решило.
      def details(count)
        leading = top(count)
        return breakdown(count) if leading.empty?

        "#{breakdown(count)}; #{leading.first.explain}"
      end
    end

    attr_reader :config, :stats, :factors

    def initialize(config: ScoringConfig.default, stats: nil)
      @config = config
      @stats = stats
      config.validate_weights!(Factors.keys)
      @factors = build_factors
      @tie_break = validate_tie_break(config.tie_break)
    end

    # Провайдеры по убыванию скора. Порядок полностью детерминирован: при равных скорах
    # решает цепочка tie_break из конфига, последним звеном — исходный порядок пула.
    def rank(providers, operation, state)
      scored = Array(providers).each_with_index.map do |provider, index|
        [score(provider, operation, state), index]
      end

      scored.sort_by { |item, index| sort_key(item, index) }.map(&:first)
    end

    def score(provider, operation, state)
      contributions = factors.map do |factor|
        weight = config.weight(factor.key)
        assessment = factor.assess(provider, operation, state)
        value = finite(assessment.value)

        Contribution.new(
          factor: factor.key,
          value: value,
          weight: weight,
          contribution: weight * value,
          explain: assessment.explain
        )
      end

      total = contributions.sum(&:contribution)
      Scored.new(provider: provider, score: total, contributions: contributions)
    end

    private

    # Последний рубеж перед сортировкой: один NaN в одном факторе роняет весь порядок
    # (comparison of Float with NaN failed), причём падает не фактор, а сортировка,
    # и по трассировке не видно, кто виноват.
    def finite(value)
      number = value.to_f
      number.finite? ? number : 0.0
    end

    def build_factors
      Factors.keys.filter_map do |key|
        next if config.weight(key).zero?

        Factors.build(key, options: config.options(key), epsilon: config.epsilon, stats: stats)
      end
    end

    def sort_key(scored, index)
      [-scored.score.round(ROUND_DP)] + @tie_break.map { |rule| tie_value(rule, scored, index) }
    end

    def tie_value(rule, scored, index)
      provider = scored.provider

      case rule
      when "priority_asc" then provider.priority || Float::INFINITY
      when "conversion_desc" then -(provider.conversion_24h || 0).to_f
      when "name_asc" then provider.name
      else index
      end
    end

    def validate_tie_break(rules)
      unknown = rules - TIE_BREAKS
      unless unknown.empty?
        raise InvalidInputError,
              "неизвестные правила tie_break: #{unknown.join(', ')}; есть: #{TIE_BREAKS.join(', ')}"
      end

      # Исходный порядок пула — последнее слово, иначе полного детерминизма нет.
      rules.include?("input_order") ? rules : rules + ["input_order"]
    end
  end
end
