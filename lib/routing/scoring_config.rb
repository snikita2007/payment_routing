require "yaml"

require_relative "errors"

module Routing
  # Настройки скоринга: веса факторов и параметры их расчёта.
  #
  # Полные дефолты лежат здесь, в коде, а YAML их только переопределяет — глубоко,
  # ключ за ключом. Поэтому и частичный config/scoring.yml, и полное его отсутствие
  # одинаково рабочие: решение не падает на непропатченном окружении.
  #
  # Профиль — именованный набор весов плюс, при желании, свои параметры секций.
  # Переключение профиля не трогает код: ScoringConfig.load(path, profile: "declared").
  class ScoringConfig
    DEFAULT_PATH = File.expand_path("../../config/scoring.yml", __dir__).freeze

    DEFAULTS = {
      "profile" => "hybrid",
      "profiles" => {
        "hybrid" => {
          "weights" => {
            "traffic_share" => 0.20,
            "volume_share" => 0.15,
            "conversion" => 0.30,
            "priority" => 0.10,
            "turnover_min" => 0.15,
            "load" => 0.05,
            "speed" => 0.05
          }
        },
        "declared" => {
          "weights" => {
            "traffic_share" => 0.25,
            "volume_share" => 0.20,
            "conversion" => 0.25,
            "priority" => 0.10,
            "turnover_min" => 0.15,
            "load" => 0.05,
            "speed" => 0.00
          },
          "conversion" => { "source" => "declared" }
        },
        "priority_only" => {
          "weights" => {
            "traffic_share" => 0.00,
            "volume_share" => 0.00,
            "conversion" => 0.00,
            "priority" => 1.00,
            "turnover_min" => 0.00,
            "load" => 0.00,
            "speed" => 0.00
          },
          # Заглушка выбирала min_by(priority), то есть при равных приоритетах — первого
          # по порядку пула. Чтобы профиль повторял её и в этом случае, ничего, кроме
          # порядка, для разрешения ничьей брать нельзя.
          "tie_break" => ["input_order"]
        }
      },
      "traffic_share" => { "mode" => "expected" },
      "volume_share" => { "mode" => "expected" },
      "conversion" => {
        "source" => "history",
        "blend_history_weight" => 0.7,
        "slice_weights" => {
          "overall" => 0.50,
          "bank" => 0.25,
          "amount" => 0.15,
          "card" => 0.10
        },
        "prior_strength" => 5,
        "confidence_weighting" => true,
        "amount_buckets" => [5000, 50000, 100000]
      },
      "speed" => {
        "source" => "declared",
        "latency_scale_sec" => 120
      },
      "epsilon" => 1.0e-06,
      "tie_break" => %w[priority_asc conversion_desc input_order],
      "explain_top_factors" => 3
    }.freeze

    attr_reader :profile_name, :raw

    # path = nil — взять config/scoring.yml, если он есть; иначе одни дефолты.
    def self.load(path = DEFAULT_PATH, profile: nil)
      new(read_file(path), profile: profile)
    end

    def self.default
      @default ||= load
    end

    def self.read_file(path)
      return {} if path.nil? || !File.file?(path)

      parsed = YAML.safe_load_file(path, permitted_classes: [], aliases: true)
      return {} if parsed.nil?

      unless parsed.is_a?(Hash)
        raise InvalidInputError, "#{path}: ожидался объект с настройками, получено #{parsed.class}"
      end

      parsed
    rescue Psych::Exception => e
      raise InvalidInputError, "#{path}: не разбирается как YAML — #{e.message}"
    end

    def initialize(overrides = {}, profile: nil)
      @raw = deep_merge(DEFAULTS, stringify(overrides))
      @profile_name = (profile || @raw["profile"]).to_s
      @resolved = resolve_profile(@profile_name)
    end

    # Тот же конфиг с другим профилем — для CLI-флага --profile и для тестов.
    def with_profile(name)
      self.class.new(raw, profile: name)
    end

    def profiles
      raw["profiles"].keys
    end

    def weights
      @resolved["weights"]
    end

    def weight(key)
      weights.fetch(key.to_s, 0.0).to_f
    end

    # Параметры секции с учётом переопределений активного профиля.
    def options(section)
      value = @resolved[section.to_s]
      value.is_a?(Hash) ? value : {}
    end

    def epsilon
      @resolved["epsilon"].to_f
    end

    def tie_break
      Array(@resolved["tie_break"]).map(&:to_s)
    end

    def explain_top_factors
      @resolved["explain_top_factors"].to_i
    end

    # Опечатка в имени фактора не должна проходить молча: вес 0.30, написанный с ошибкой,
    # просто исчезнет из формулы, и понять это по результату будет нечем.
    def validate_weights!(known_keys)
      known = known_keys.map(&:to_s)
      unknown = weights.keys - known
      unless unknown.empty?
        raise InvalidInputError,
              "профиль #{profile_name}: неизвестные факторы в weights — #{unknown.join(', ')}; " \
              "известные: #{known.sort.join(', ')}"
      end

      if weights.values.all? { |value| value.to_f.zero? }
        raise InvalidInputError,
              "профиль #{profile_name}: все веса нулевые, скор у всех выйдет одинаковый " \
              "и выбор сведётся к tie_break"
      end

      self
    end

    # Веса не обязаны давать в сумме единицу — на порядок ранжирования это не влияет.
    # Но если они дают, скажем, 0.7, то заявленные 0.30 у конверсии на деле означают 43%
    # решения, и читать конфиг становится нельзя. Поэтому не ошибка, а предупреждение.
    def weights_sum
      weights.values.sum(&:to_f)
    end

    def weights_sum_warning
      total = weights_sum
      return nil if (total - 1.0).abs < 1e-9

      "профиль #{profile_name}: веса дают в сумме #{format('%.2f', total)}, а не 1.00 — " \
        "доли факторов в конфиге читаются не как есть"
    end

    private

    # Профиль накладывается поверх верхнего уровня: его weights становятся активными,
    # а остальные ключи (например conversion.source) переопределяют одноимённые секции.
    def resolve_profile(name)
      profile = raw["profiles"][name]
      unless profile.is_a?(Hash)
        raise InvalidInputError,
              "неизвестный профиль #{name.inspect}; есть: #{profiles.sort.join(', ')}"
      end

      base = raw.reject { |key, _| key == "profiles" || key == "profile" }
      deep_merge(base, profile)
    end

    def deep_merge(base, patch)
      base.merge(patch) do |_key, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          deep_merge(old_value, new_value)
        else
          new_value
        end
      end
    end

    def stringify(value)
      case value
      when Hash then value.to_h { |key, nested| [key.to_s, stringify(nested)] }
      when Array then value.map { |item| stringify(item) }
      else value
      end
    end
  end
end
