require_relative "base_factor"

module Routing
  module Factors
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

      # λ = ln2 / T½ — константа фактора, а не заявки: считаем один раз, а не на каждой оценке.
      def decay
        @decay ||= Math.log(2) / half_life
      end

      def accumulate(events, now)
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
  end
end
