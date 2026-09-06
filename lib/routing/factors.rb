require_relative "conversion_stats"

module Routing
  # Soft-факторы: слагаемые формулы ранжирования.
  #
  #   Score = w_t·D_t + w_v·D_v + w_c·C + w_p·P + w_m·M + w_l·L + w_s·Speed
  #
  # Один фактор — один класс с #assess. Добавить правило = добавить класс, зарегистрировать
  # его и дать ему вес в config/scoring.yml; ни SoftScorer, ни Router при этом не меняются.
  #
  # #assess возвращает значение вместе с человекочитаемым объяснением, одним объектом.
  # Это не украшательство: если считать число в одном месте, а текст к нему собирать в другом,
  # они однажды разойдутся, и отчёт начнёт врать.
  #
  # Два разных «ничего не известно»:
  #   - цель не задана (нет traffic_percentage, нет daily_turnover_min) → 0.0, фактор молчит;
  #   - вероятность неизвестна (нет ни истории, ни conversion_24h) → 0.5, честная середина.
  # Ставить 0.0 там, где речь о вероятности, значит утверждать «конверсия нулевая», а это
  # не отсутствие знания, а очень сильное знание.
  module Factors
    NEUTRAL = 0.0
    UNKNOWN_PROBABILITY = 0.5

    # Одно слагаемое: значение фактора и то, откуда оно взялось.
    Assessment = Struct.new(:value, :explain, keyword_init: true)

    class BaseFactor
      attr_reader :options, :epsilon, :stats

      def initialize(options: {}, epsilon: 1.0e-06, stats: nil)
        @options = options || {}
        @epsilon = epsilon
        @stats = stats
      end

      def key
        self.class::KEY
      end

      def assess(_provider, _operation, _state)
        raise NotImplementedError, "#{self.class}#assess"
      end

      # Удобство для тестов и для мест, где текст не нужен.
      def score(provider, operation, state)
        assess(provider, operation, state).value
      end

      private

      def result(value, explain)
        Assessment.new(value: value, explain: explain)
      end

      # NaN в скоре роняет сортировку целиком (comparison of Float with NaN failed),
      # причём не там, где он родился, а много позже. Гасим на месте.
      def clip(value, low, high)
        number = value.to_f
        return low if number.nan?

        number.clamp(low, high)
      end

      # Отклонение факта от цели в долях, буквально как в формуле:
      #   D = clip((target − current) / (target + ε), −1, 1)
      #
      # Цель ноль разбираем отдельной веткой, а не через ε: 0/ε даёт 0, то есть «в цели»,
      # хотя провайдеру с нулевой целевой долей не должно доставаться ничего.
      def ratio_deviation(target, current)
        return current.positive? ? -1.0 : 0.0 if target <= 0

        clip((target - current) / (target + epsilon), -1.0, 1.0)
      end

      # То же намерение, но через ожидаемое количество, а не через долю.
      #
      # Доля не определена, пока ничего не роздано: на первой заявке (target − 0)/target = 1
      # у всех сразу, и фактор перестаёт отличать цель 40% от цели 25% ровно там, где выбор
      # ещё ничем не связан. Ожидание же считается всегда: при пустом состоянии оно равно
      # target/100 и сохраняет порядок целей.
      #
      # Знаменатель — «одна заявка»: отклонение в один шаг даёт единицу, дальше клип.
      def expected_deviation(expected, actual, unit)
        clip((expected - actual) / [expected, unit].max.to_f, -1.0, 1.0)
      end

      def fmt(value)
        return value.to_s unless value.is_a?(Numeric)
        return "∞" if value == Float::INFINITY

        value == value.to_i ? value.to_i.to_s : format("%.2f", value)
      end

      def pct(value)
        format("%.1f%%", value)
      end
    end

    # Общее для двух факторов целевой доли: обе считают одно и то же отклонение,
    # разница только в том, что мерить — заявки или деньги.
    #
    # mode: expected — через ожидаемое количество (по умолчанию)
    # mode: ratio    — буквально по формуле, через доли в процентах
    class ShareFactor < BaseFactor
      EXPECTED = "expected".freeze
      RATIO = "ratio".freeze

      def assess(provider, operation, state)
        target = target_for(provider)
        return result(NEUTRAL, "#{target_field} не задан") if target.nil?

        current = current_share(state, provider)
        value = mode == RATIO ? ratio_value(target, current) : expected_value(target, operation, state, provider)

        result(value, explain_text(target, current, value))
      end

      private

      def mode
        options.fetch("mode", EXPECTED).to_s
      end

      def ratio_value(target, current)
        ratio_deviation(target, current)
      end

      def expected_value(target, operation, state, provider)
        unit = unit_for(operation)
        expected = target / 100.0 * (total_for(state) + unit)
        expected_deviation(expected, actual_for(state, provider), unit)
      end

      def explain_text(target, current, value)
        gap = (target - current).abs
        word = value.negative? ? "перебор" : "недобор"

        "#{label}: цель #{fmt(target)}%, факт #{pct(current)} (#{word} #{fmt(gap)} п.п.)"
      end
    end

    # D_t — целевая доля по количеству заявок.
    # Недобравший долю поднимается, перебравший опускается; за прогон это стягивает
    # фактическое распределение к traffic_percentage.
    class TrafficShareFactor < ShareFactor
      KEY = "traffic_share".freeze

      private

      def label
        "доля по количеству"
      end

      def target_field
        "traffic_percentage"
      end

      def target_for(provider)
        provider.traffic_percentage
      end

      def current_share(state, provider)
        state.count_share_pct(provider)
      end

      def total_for(state)
        state.total_routed_count
      end

      def actual_for(state, provider)
        state.routed_count(provider)
      end

      def unit_for(_operation)
        1
      end
    end

    # D_v — то же самое, но доля считается в деньгах.
    # Расходится с D_t не случайно: один чек на 150 000 весит как двадцать по 8 000,
    # и провайдер, набравший свою долю заявок, может недобирать половину объёма.
    class VolumeShareFactor < ShareFactor
      KEY = "volume_share".freeze

      private

      def label
        "доля по объёму"
      end

      def target_field
        "volume_share_pct"
      end

      def target_for(provider)
        provider.volume_share_pct
      end

      def current_share(state, provider)
        state.volume_share_pct(provider)
      end

      def total_for(state)
        state.total_routed_amount
      end

      def actual_for(state, provider)
        state.routed_amount(provider)
      end

      # Шаг измеряется суммой текущей заявки: недобор в один такой чек и есть единица.
      def unit_for(operation)
        operation.amount
      end
    end

    # C — вероятность одобрения. Источник переключается конфигом:
    # history (срезы из CSV со сглаживанием), declared (conversion_24h) или их смесь.
    class ConversionFactor < BaseFactor
      KEY = "conversion".freeze

      HISTORY = "history".freeze
      DECLARED = "declared".freeze
      BLEND = "blend".freeze

      def assess(provider, operation, _state)
        case source
        when DECLARED then declared(provider)
        when BLEND then blend(provider, operation)
        else history(provider, operation)
        end
      end

      private

      def source
        options.fetch("source", HISTORY).to_s
      end

      def blend_weight
        options.fetch("blend_history_weight", 0.7).to_f.clamp(0.0, 1.0)
      end

      def history(provider, operation)
        return declared(provider) if stats.nil?

        estimate = stats.estimate(
          provider,
          bank: operation.bank,
          amount: operation.amount,
          card_brand: card_brand(operation)
        )
        result(estimate.value, "конверсия по истории #{estimate}")
      end

      def declared(provider)
        value = normalize(provider.conversion_24h)
        return result(UNKNOWN_PROBABILITY, "conversion_24h не задан, берём #{UNKNOWN_PROBABILITY}") if value.nil?

        result(value, "conversion_24h #{format('%.3f', value)}")
      end

      def blend(provider, operation)
        from_history = history(provider, operation)
        from_declared = declared(provider)
        weight = blend_weight
        value = weight * from_history.value + (1 - weight) * from_declared.value

        result(value, format("конверсия %.3f = %.2f×история %.3f + %.2f×заявленная %.3f",
                             value, weight, from_history.value, 1 - weight, from_declared.value))
      end

      # В providers.json conversion_24h — доля (0.87). Но то же поле легко приходит
      # в процентах (87), и делить одно на другое одинаково нельзя.
      #
      # Граница — единица, и на 0.5 или 1 правило принципиально угадать не может.
      # Клип нужен для мусора: 150 без него дало бы 1.5, и фактор с весом 0.30 внёс бы
      # 0.45, выйдя за собственный бюджет весов.
      def normalize(value)
        return nil if value.nil?

        (value > 1 ? value / 100.0 : value.to_f).clamp(0.0, 1.0)
      end

      def card_brand(operation)
        operation.raw["card_brand"] || operation.raw[:card_brand]
      end
    end

    # P — позиция в каскаде. priority 1 → 1.0, 2 → 0.5, 3 → 0.33.
    class PriorityFactor < BaseFactor
      KEY = "priority".freeze

      def assess(provider, _operation, _state)
        priority = provider.priority
        return result(NEUTRAL, "priority не задан") if priority.nil? || priority <= 0

        value = 1.0 / priority
        result(value, "priority #{fmt(priority)} → #{format('%.2f', value)}")
      end
    end

    # M — минимальный дневной оборот, который провайдеру обещали набрать.
    # Пока обязательство не выполнено, провайдер получает надбавку; как только
    # оборот дотянут, фактор гаснет сам.
    class TurnoverMinFactor < BaseFactor
      KEY = "turnover_min".freeze

      def assess(provider, _operation, state)
        target = provider.daily_turnover_min
        return result(NEUTRAL, "daily_turnover_min не задан") if target.nil?
        return result(NEUTRAL, "daily_turnover_min нулевой — обязательства нет") if target <= 0

        current = state.daily_approved_amount(provider)
        value = clip((target - current) / (target + epsilon), 0.0, 1.0)

        if value.zero?
          return result(value, "минимальный оборот набран: #{fmt(current)} из #{fmt(target)}")
        end

        result(value, "до daily_turnover_min не хватает #{fmt(target - current)} " \
                      "(#{fmt(current)} из #{fmt(target)})")
      end
    end

    # L — свободная мощность. Дополняет hard-проверки in-progress: те отвечают «влезет или нет»,
    # а этот — «насколько провайдер уже занят». Загруженный на 90% формально проходит,
    # но отправлять к нему следующую заявку хуже, чем к свободному.
    class LoadFactor < BaseFactor
      KEY = "load".freeze

      def assess(provider, _operation, state)
        by_count = utilization(state.in_progress_count(provider), provider.in_progress_count_limit)
        by_amount = utilization(state.in_progress_amount(provider), provider.in_progress_amount_limit)
        busiest = [by_count, by_amount].max
        value = clip(1.0 - busiest, 0.0, 1.0)

        result(value, "загрузка in-progress #{pct(busiest * 100)} " \
                      "(#{fmt(state.in_progress_count(provider))}/#{fmt(provider.in_progress_count_limit)} шт, " \
                      "#{fmt(state.in_progress_amount(provider))}/#{fmt(provider.in_progress_amount_limit)} ₽)")
      end

      private

      def utilization(current, limit)
        return 0.0 if limit.nil? || limit == Float::INFINITY
        return 1.0 if limit <= 0

        clip(current / limit.to_f, 0.0, 1.0)
      end
    end

    # Speed — скорость провайдера. Шкала абсолютная: latency_scale_sec секунд считаем
    # «совсем медленно». Min-max по пулу здесь не годится — он превратил бы разницу
    # 29 с против 38 с в 1.0 против 0.0 и менял бы оценку одного провайдера
    # в зависимости от того, кто ещё прошёл фильтры на этой заявке.
    class SpeedFactor < BaseFactor
      KEY = "speed".freeze

      DEFAULT_SCALE_SEC = 120.0

      def assess(provider, _operation, _state)
        latency, source = latency_for(provider)
        return result(NEUTRAL, "нет данных о времени ответа") if latency.nil?

        value = clip(1.0 - latency / scale, 0.0, 1.0)
        result(value, "#{source} #{fmt(latency)} с из #{fmt(scale)} → #{format('%.2f', value)}")
      end

      private

      def scale
        value = options.fetch("latency_scale_sec", DEFAULT_SCALE_SEC).to_f
        value.positive? ? value : DEFAULT_SCALE_SEC
      end

      # source: declared — avg_latency_sec из providers.json, история как запасной вариант
      #         history  — наоборот, верим замерам, а не заявленному
      #
      # Различие не умозрительное: providers.json объявляет quickpay самым быстрым (29 с),
      # а по истории медиана успешных заявок у него выше, чем у vipay.
      def latency_for(provider)
        declared = [provider.avg_latency_sec, "avg_latency_sec"]
        measured = [stats && stats.median_latency(provider), "медиана по истории"]
        order = options.fetch("source", "declared").to_s == "history" ? [measured, declared] : [declared, measured]

        order.find { |value, _| !value.nil? } || [nil, nil]
      end
    end

    # RecentFailure — штраф за свежие сбои с экспоненциальным затуханием:
    #
    #   λ = ln2 / half_life_sec
    #   w_j = exp(−λ · (сейчас − t_j))
    #   RecentFailure = (Σ w_j·failure_j + α·baseline) / (Σ w_j + α)
    #   значение = −RecentFailure                          то есть [−1, 0]
    #
    # Отличается от conversion горизонтом: тот меряет долгосрочную надёжность по всей истории,
    # этот — «провайдер сыпется прямо сейчас». Поэтому база по умолчанию нулевая: провайдер без
    # свежих сбоев штрафа не получает вовсе. Если взять за базу историческую долю сбоев
    # (baseline: historical), фактор превратится в conversion со знаком минус.
    #
    # α в знаменателе делает сразу две вещи: убирает 0/0 при отсутствии событий и не даёт
    # одному-единственному сбою выкрутить штраф на максимум (при α = 2 он даёт 0.33, а не 1.0).
    class RecentFailureFactor < BaseFactor
      KEY = "recent_failure".freeze

      DEFAULT_HALF_LIFE_SEC = 45.0
      DEFAULT_PRIOR_STRENGTH = 1.0
      HISTORICAL = "historical".freeze

      def assess(provider, operation, state)
        now = operation.created_at || state.now
        events = visible_events(provider, state, now)
        weight_sum, failure_sum = accumulate(events, now)

        base = baseline(provider)
        penalty = (failure_sum + prior_strength * base) / (weight_sum + prior_strength)
        value = -clip(penalty, 0.0, 1.0)

        result(value, explain_text(events.size, weight_sum, penalty))
      end

      private

      def half_life
        value = options.fetch("half_life_sec", DEFAULT_HALF_LIFE_SEC).to_f
        value.positive? ? value : DEFAULT_HALF_LIFE_SEC
      end

      def prior_strength
        value = options.fetch("prior_strength", DEFAULT_PRIOR_STRENGTH).to_f
        value.positive? ? value : DEFAULT_PRIOR_STRENGTH
      end

      def baseline(provider)
        return 0.0 unless options.fetch("baseline", "none").to_s == HISTORICAL
        return 0.0 if stats.nil?

        clip(stats.failure_rate(provider), 0.0, 1.0)
      end

      # Только то, что известно к моменту текущей заявки. Исход заявки, отправленной
      # 30 секунд назад с задержкой 50 секунд, ещё не пришёл — заглядывать вперёд нельзя.
      def visible_events(provider, state, now)
        events = state.outcomes(provider)
        events += stats.outcome_events(provider) if include_history? && stats

        events.select { |at, _| at && at <= now }
      end

      def include_history?
        options.fetch("include_history", false) ? true : false
      end

      def accumulate(events, now)
        decay = Math.log(2) / half_life
        weight_sum = 0.0
        failure_sum = 0.0

        events.each do |at, failure|
          age = now - at
          age = 0.0 if age.negative?
          weight = Math.exp(-decay * age)
          weight_sum += weight
          failure_sum += weight * failure
        end

        [weight_sum, failure_sum]
      end

      def explain_text(count, weight_sum, penalty)
        return "свежих сбоев нет" if count.zero?

        format("свежие сбои: штраф %.2f по %d событиям (вес %.2f, T½ %s с)",
               penalty, count, weight_sum, fmt(half_life))
      end
    end

    REGISTRY = {}

    def self.register(klass)
      REGISTRY[klass::KEY] = klass
    end

    def self.keys
      REGISTRY.keys
    end

    def self.fetch(key)
      REGISTRY[key.to_s] ||
        raise(ArgumentError, "неизвестный фактор #{key.inspect}; есть: #{keys.sort.join(', ')}")
    end

    def self.build(key, options: {}, epsilon: 1.0e-06, stats: nil)
      fetch(key).new(options: options, epsilon: epsilon, stats: stats)
    end

    [
      TrafficShareFactor,
      VolumeShareFactor,
      ConversionFactor,
      PriorityFactor,
      TurnoverMinFactor,
      LoadFactor,
      SpeedFactor,
      RecentFailureFactor
    ].each { |klass| register(klass) }
  end
end
