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
      :daily_approved_amount,
      :in_progress_count,
      :in_progress_amount,
      :request_times,
      keyword_init: true
    )

    attr_reader :clock

    def initialize(providers, clock: -> { Time.now })
      @clock = clock
      @counters = {}
      Array(providers).each { |provider| register(provider) }
    end

    def register(provider)
      @counters[provider.name] ||= Counters.new(
        daily_approved_amount: provider.daily_approved_amount,
        in_progress_count: provider.in_progress_count,
        in_progress_amount: provider.in_progress_amount,
        request_times: []
      )
    end

    def now
      clock.call
    end

    def daily_approved_amount(provider)
      counters_for(provider).daily_approved_amount
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

    # Отметить факт отправки заявки провайдеру — этим двигается счётчик интенсивности.
    def record_request(provider, at: now)
      counters_for(provider).request_times << at
      self
    end

    def add_daily_amount(provider, amount)
      counters_for(provider).daily_approved_amount += amount
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
      name = provider.is_a?(Provider) ? provider.name : provider.to_s
      @counters[name] || raise(ArgumentError, "провайдер #{name} не зарегистрирован в состоянии")
    end
  end
end
