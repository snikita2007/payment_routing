require_relative "provider"

module Routing
  # Изменяемое состояние провайдеров по ходу очереди: оборот, in-progress, отметки времени
  # для расчёта интенсивности. Очередь обрабатывается последовательно, порядок значим.
  #
  # Hard-проверки читают счётчики отсюда, а не из Provider: значения в providers.json —
  # только начальная точка, дальше они расходятся с реальностью после первой же заявки.
  class RoutingState
    RATE_WINDOW_SEC = 60

    Counters = Struct.new(
      :daily_turnover,
      :in_progress_count,
      :in_progress_amount,
      :request_times,
      :routed_count,
      :routed_amount,
      :outcomes,
      keyword_init: true
    )

    attr_reader :clock, :total_routed_count, :total_routed_amount

    def initialize(providers, clock: -> { Time.now })
      @clock = clock
      @counters = {}
      @total_routed_count = 0
      @total_routed_amount = 0
      Array(providers).each { |provider| register(provider) }
    end

    def register(provider)
      @counters[provider.name] ||= Counters.new(
        daily_turnover: provider.daily_approved_amount,
        in_progress_count: provider.in_progress_count,
        in_progress_amount: provider.in_progress_amount,
        request_times: [],
        routed_count: 0,
        routed_amount: 0,
        outcomes: []
      )
    end

    def now
      clock.call
    end

    # Оборот, набранный провайдером за сутки. Именно оборот, а не одобренная сумма:
    # сюда идёт каждая отправленная заявка, независимо от того, чем она кончилась.
    # Стартует с daily_approved_amount из providers.json — того, что провайдер набрал
    # до начала прогона.
    def daily_turnover(provider)
      counters_for(provider).daily_turnover
    end

    def in_progress_count(provider)
      counters_for(provider).in_progress_count
    end

    def in_progress_amount(provider)
      counters_for(provider).in_progress_amount
    end

    # Сколько заявок ушло провайдеру за последнюю минуту (окно скользящее).
    def requests_in_last_minute(provider, at: now)
      times = counters_for(provider).request_times
      times.reject! { |time| at - time > RATE_WINDOW_SEC }
      times.size
    end

    # Сколько заявок и денег ушло провайдеру за этот прогон.
    #
    # Отдельно от daily_turnover: тот стартует с уже накопленного за сутки значения
    # (у vipay это 3.2 млн из providers.json), а доля по количеству и объёму считается
    # от того, что раздал сам роутер, — иначе первая же заявка сравнивалась бы с чужой историей.
    def routed_count(provider)
      counters_for(provider).routed_count
    end

    def routed_amount(provider)
      counters_for(provider).routed_amount
    end

    # Фактическая доля провайдера в процентах — то, с чем soft-цели сравнивают целевую долю.
    # До первой заявки доля не определена; отдаём 0, чтобы все выглядели одинаково недобравшими.
    def count_share_pct(provider)
      return 0.0 if total_routed_count.zero?

      routed_count(provider) * 100.0 / total_routed_count
    end

    def volume_share_pct(provider)
      return 0.0 if total_routed_amount.zero?

      routed_amount(provider) * 100.0 / total_routed_amount
    end

    # toward_share: false — заявка провайдеру ушла, но в знаменатель долей не идёт.
    # Так учитывается fallback на self-provider: целевые доли (40/35/25) заданы по внешним
    # провайдерам и дают в сумме 100, поэтому заявка, ушедшая в последнюю инстанцию,
    # разбавила бы их все сразу и держала бы недобор положительным до конца очереди.
    def record_routed(provider, amount, toward_share: true)
      counters = counters_for(provider)
      counters.routed_count += 1
      counters.routed_amount += amount

      if toward_share
        @total_routed_count += 1
        @total_routed_amount += amount
      end

      self
    end

    # Журнал исходов: [момент, когда исход стал известен; 1 — сбой, 0 — успех].
    #
    # Состояние их только хранит, затухание считает фактор — то же разделение, что у остальных
    # счётчиков. Ключевое здесь at: это не момент отправки заявки, а момент, когда ответ пришёл.
    # Заявка, ушедшая 30 секунд назад с задержкой 50 секунд, ещё ничего о провайдере не говорит.
    def record_outcome(provider, at:, failure:)
      counters_for(provider).outcomes << [at, failure ? 1 : 0]
      self
    end

    def outcomes(provider)
      counters_for(provider).outcomes
    end

    # Отметить факт отправки заявки провайдеру — этим двигается счётчик интенсивности.
    def record_request(provider, at: now)
      counters_for(provider).request_times << at
      self
    end

    def add_daily_turnover(provider, amount)
      counters_for(provider).daily_turnover += amount
      self
    end

    def add_in_progress(provider, amount)
      counters = counters_for(provider)
      counters.in_progress_count += 1
      counters.in_progress_amount += amount
      self
    end

    def release_in_progress(provider, amount)
      counters = counters_for(provider)
      counters.in_progress_count = [counters.in_progress_count - 1, 0].max
      counters.in_progress_amount = [counters.in_progress_amount - amount, 0].max
      self
    end

    private

    def counters_for(provider)
      name = Provider.name_of(provider)
      @counters[name] || raise(ArgumentError, "провайдер #{name} не зарегистрирован в состоянии")
    end
  end
end
