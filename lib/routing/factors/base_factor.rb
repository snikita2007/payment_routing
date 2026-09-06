require_relative "../format"

module Routing
  module Factors
    # Два разных «ничего не известно», и путать их нельзя:
    #
    #   - цель не задана (нет traffic_percentage, нет daily_turnover_min) → 0.0, фактор молчит;
    #   - вероятность неизвестна (нет ни истории, ни conversion_24h) → 0.5, честная середина.
    #
    # Ставить 0.0 там, где речь о вероятности, значит утверждать «конверсия нулевая»,
    # а это не отсутствие знания, а очень сильное знание.
    NEUTRAL = 0.0
    UNKNOWN_PROBABILITY = 0.5

    # Одно слагаемое: значение фактора и то, откуда оно взялось.
    #
    # Число и текст к нему возвращаются вместе не для красоты: посчитай мы значение здесь,
    # а объяснение собери отдельно в отчёте — они однажды разойдутся, и отчёт начнёт врать.
    Assessment = Struct.new(:value, :explain, keyword_init: true)

    # Общий предок всех факторов: обёртки над Assessment и арифметика отклонения от цели,
    # которой пользуются несколько правил сразу.
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
        Format.number(value)
      end

      def pct(value)
        Format.pct(value)
      end
    end
  end
end
