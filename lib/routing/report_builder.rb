require "time"

require_relative "attempt"
require_relative "decisions_file"
require_relative "router"

module Routing
  # Аналитика прогона в формате routing_report_test.json.
  #
  # Обязательные поля заданы ТЗ (period, total_operations, distribution, skip_reasons,
  # projected_daily_utilization, recommendations); остальное — доп. поля, которые ТЗ
  # разрешает добавлять, и которые закрывают критерий «проанализированы успешность,
  # отказы, загрузка и использование лимитов».
  #
  # Считается по готовому Pipeline::Result, то есть по тем же решениям, что уходят
  # в routing_decisions_test.json: отчёт обязан сходиться с ними до цифры.
  #
  # Главное здесь не таблицы, а findings и recommendations: критерий требует не «показать
  # отклонение», а назвать его причину и конкретный параметр к изменению.
  class ReportBuilder
    # Отклонение доли, начиная с которого это уже не шум, а расхождение с целью.
    SIGNIFICANT_DEVIATION_PP = 5.0
    # Дневной лимит выбран настолько, что до конца суток провайдер до цели не дотянет.
    HIGH_UTILIZATION_PCT = 80.0
    # Одобрений меньше этого — провайдер тянет вниз общую успешность.
    LOW_APPROVAL_PCT = 60.0

    attr_reader :result

    def self.write(path, result)
      JsonFile.write(path, new(result).to_h)
    end

    def initialize(result)
      @result = result
    end

    def to_h
      {
        "period" => period,
        "profile" => result.config.profile_name,
        "total_operations" => operations.size,
        "distribution" => distribution,
        "outcomes" => outcomes,
        "skip_reasons" => skip_reasons,
        "outscored_by_score" => outscored_count,
        "projected_daily_utilization" => utilization,
        "fallback" => fallback_section,
        "findings" => findings,
        "recommendations" => recommendations
      }
    end

    private

    def decisions = result.decisions
    def operations = result.operations
    def state = result.state
    def external = result.external

    # Сутки, за которые отчитываемся. Берём из самих заявок, а не из системных часов:
    # очередь может обрабатываться когда угодно, а период относится к её данным.
    def period
      days = operations.filter_map { |op| op.created_at&.strftime("%Y-%m-%d") }.uniq.sort
      return Time.now.strftime("%Y-%m-%d") if days.empty?

      days.size == 1 ? days.first : "#{days.first}..#{days.last}"
    end

    # Доли считаются по внешним провайдерам и в сумме дают 100. Заявки, ушедшие в fallback,
    # в знаменатель не идут — иначе целевые 40/35/25 разбавлялись бы и все выглядели бы
    # недобравшими. Fallback вынесен отдельной секцией.
    def distribution
      external.to_h do |provider|
        actual = round1(state.count_share_pct(provider))
        target = provider.traffic_percentage&.to_f
        volume_actual = round1(state.volume_share_pct(provider))
        volume_target = provider.volume_share_pct&.to_f

        [provider.name, {
          "count" => state.routed_count(provider),
          "share_pct" => actual,
          "target_pct" => target,
          "deviation_pp" => deviation(actual, target),
          "volume" => state.routed_amount(provider).round,
          "volume_share_pct" => volume_actual,
          "volume_target_pct" => volume_target,
          "volume_deviation_pp" => deviation(volume_actual, volume_target)
        }]
      end
    end

    # Успешность и отказы: и в целом, и по каждому провайдеру.
    def outcomes
      { "total" => outcome_stats(decisions), "by_provider" => outcomes_by_provider }
    end

    def outcomes_by_provider
      decisions.group_by { |decision| provider_name(decision) }
               .transform_values { |group| outcome_stats(group) }
    end

    def outcome_stats(group)
      simulated = group.map(&:outcome).compact
      counts = ResultSimulator::STATUSES.to_h do |status|
        [status, simulated.count { |outcome| outcome.status == status }]
      end

      counts.merge(
        "total" => group.size,
        "approval_rate_pct" => percent(counts[ResultSimulator::APPROVED], simulated.size)
      )
    end

    # Причины, по которым провайдеров не допускали к заявке, — то есть hard-ограничения.
    # Проигрыш по скору сюда не идёт: это не отказ, а исход ранжирования среди допущенных,
    # и в одной таблице с «сумма вне лимита» он только мешал бы читать.
    def skip_reasons
      tally(all_skips.reject { |attempt| attempt.reason == Router::LOWER_SCORE }.map(&:reason))
    end

    def outscored_count
      all_skips.count { |attempt| attempt.reason == Router::LOWER_SCORE }
    end

    def all_skips
      @all_skips ||= decisions.flat_map { |decision| decision.attempts.select(&:skipped?) }
    end

    # Сколько дневного лимита выбрано на конец прогона. used — оборот из состояния,
    # он уже включает то, что провайдер набрал до начала очереди.
    def utilization
      result.providers.to_h do |provider|
        limit = provider.daily_amount_limit
        used = state.daily_turnover(provider).round
        unlimited = limit == Float::INFINITY

        [provider.name, {
          "used" => used,
          "limit" => unlimited ? nil : limit.round,
          "utilization_pct" => unlimited ? nil : percent(used, limit)
        }]
      end
    end

    def fallback_section
      count = decisions.count(&:fallback)
      { "count" => count, "share_pct" => percent(count, decisions.size), "provider" => SELF_PROVIDER }
    end

    # --- выводы -------------------------------------------------------------

    # Причины существенных отклонений. Отдельно от recommendations намеренно: сначала
    # диагноз с числами, потом уже что крутить. Без диагноза рекомендация — гадание.
    def findings
      notes = []

      external.each do |provider|
        gap = deviation(round1(state.count_share_pct(provider)), provider.traffic_percentage&.to_f)
        next if gap.nil? || gap.abs < SIGNIFICANT_DEVIATION_PP

        notes << deviation_finding(provider, gap)
      end

      notes.concat(utilization_findings)
      notes.concat(approval_findings)
      notes << fallback_finding if decisions.any?(&:fallback)
      notes.compact
    end

    # Недобор и перебор объясняются разными вещами, и валить их в одну формулировку нельзя.
    # Недобор — это провайдера не допускали: виноват конкретный hard-фильтр.
    # Перебор — это ему доставалось сверх цели: чаще всего потому, что на части заявок
    # он оставался единственным допущенным, и выбора не было вовсе.
    def deviation_finding(provider, gap)
      head = "#{provider.name} #{gap.negative? ? 'недобрал' : 'перебрал'} #{gap.abs} п.п. " \
             "по количеству заявок (факт #{round1(state.count_share_pct(provider))}%, " \
             "цель #{provider.traffic_percentage&.to_f}%)"

      return "#{head}; #{undershoot_cause(provider)}." if gap.negative?

      "#{head}; #{overshoot_cause(provider)}."
    end

    def undershoot_cause(provider)
      reason, count = dominant_skip(provider)
      return "лимиты и фильтры его не сдерживали — расхождение накопил сам скоринг" if reason.nil?

      "чаще всего его не допускал hard-фильтр #{reason} — #{plural(count, 'заявка', 'заявки', 'заявок')} " \
        "из #{decisions.size}"
    end

    def overshoot_cause(provider)
      forced = forced_wins(provider)
      return "на всех этих заявках он выигрывал по скору при живой конкуренции" if forced.zero?

      "на #{plural(forced, 'заявке', 'заявках', 'заявках')} он был единственным допущенным — " \
        "выбор делали hard-фильтры, а не скоринг"
    end

    # Сколько раз провайдер получил заявку без конкуренции: остальных отсеяли фильтры.
    def forced_wins(provider)
      decisions.count do |decision|
        decision.ranked.size == 1 && provider_name(decision) == provider.name
      end
    end

    # Из-за какой именно проверки провайдер терял заявки чаще всего.
    def dominant_skip(provider)
      reasons = all_skips.select { |attempt| attempt.provider == provider.name }
                         .reject { |attempt| attempt.reason == Router::LOWER_SCORE }
                         .map(&:reason)
      return [nil, 0] if reasons.empty?

      tally(reasons).max_by { |_, count| count }
    end

    def utilization_findings
      result.providers.filter_map do |provider|
        limit = provider.daily_amount_limit
        next if limit == Float::INFINITY

        used = state.daily_turnover(provider)
        share = percent(used, limit)
        next if share.nil? || share < HIGH_UTILIZATION_PCT

        "#{provider.name} выбрал #{share}% дневного лимита " \
          "(#{used.round} из #{limit.round}), запас #{(limit - used).round}."
      end
    end

    def approval_findings
      outcomes_by_provider.filter_map do |name, stats|
        rate = stats["approval_rate_pct"]
        next if rate.nil? || rate >= LOW_APPROVAL_PCT || stats["total"].zero?

        "#{name}: одобрено #{rate}% из #{stats['total']} заявок — ниже порога #{LOW_APPROVAL_PCT}%."
      end
    end

    def fallback_finding
      count = decisions.count(&:fallback)
      "#{count} заявок ушли в fallback на #{SELF_PROVIDER}: на них ни один внешний провайдер " \
        "не прошёл hard-фильтры."
    end

    # Рекомендация обязана называть конкретный параметр и число, а не «оптимизировать
    # маршрутизацию». Каждое правило ниже отвечает на findings выше.
    def recommendations
      advice = []

      result.providers.each do |provider|
        advice << limit_advice(provider)
        advice << turnover_advice(provider)
      end

      external.each { |provider| advice << share_advice(provider) }
      advice << fallback_advice if decisions.any?(&:fallback)
      advice.compact
    end

    # Провайдер у потолка дневного лимита: целевую долю до конца суток он всё равно
    # не отработает, и держать её высокой — значит гнать заявки в daily_limit_exceeded.
    def limit_advice(provider)
      limit = provider.daily_amount_limit
      return nil if limit == Float::INFINITY

      used = state.daily_turnover(provider)
      share = percent(used, limit)
      return nil if share.nil? || share < HIGH_UTILIZATION_PCT

      target = provider.traffic_percentage&.to_f
      actual = round1(state.count_share_pct(provider))
      suggested = target && [actual, target].min.round

      base = "#{provider.name} близок к дневному лимиту (#{share}%, запас #{(limit - used).round})"
      return "#{base} — поднять daily_amount_limit или снизить traffic_percentage." if target.nil?

      "#{base} — снизить traffic_percentage #{provider.name} с #{target} до #{suggested}."
    end

    # Обязательство по минимальному обороту не закрыто: либо поднимать долю, либо признать,
    # что обязательство недостижимо на такой очереди, и опустить сам порог.
    def turnover_advice(provider)
      target = provider.daily_turnover_min
      return nil if target.nil? || target <= 0

      used = state.daily_turnover(provider)
      return nil if used >= target

      "#{provider.name}: daily_turnover_min #{target.round} не набран (#{used.round}, " \
        "не хватает #{(target - used).round}) — поднять traffic_percentage или опустить " \
        "daily_turnover_min до #{used.round}."
    end

    # Устойчивое отклонение доли. Что именно крутить, зависит от причины, а не от знака:
    #
    #   недобор из-за hard-фильтра  → цель недостижима, снижать саму цель или ограничение
    #   перебор без конкуренции     → пул слишком узкий, весами это не лечится
    #   и то и другое при свободных лимитах → мал вес traffic_share
    #
    # Фактор D_t тянет к цели в обе стороны (недобравшего поднимает, перебравшего опускает),
    # поэтому при живой конкуренции ответ на любой знак отклонения один: поднять его вес.
    def share_advice(provider)
      target = provider.traffic_percentage&.to_f
      actual = round1(state.count_share_pct(provider))
      gap = deviation(actual, target)
      return nil if gap.nil? || gap.abs < SIGNIFICANT_DEVIATION_PP

      if gap.negative?
        reason, count = dominant_skip(provider)
        if reason
          return "#{provider.name}: цель #{target}% недостижима — по #{reason} отсеяно " \
                 "#{plural(count, 'заявка', 'заявки', 'заявок')}. " \
                 "Снизить traffic_percentage #{provider.name} до #{actual.round} " \
                 "или ослабить само ограничение."
        end
      elsif forced_wins(provider).positive?
        return "#{provider.name}: перебор #{gap} п.п., причём на " \
               "#{plural(forced_wins(provider), 'заявке', 'заявках', 'заявках')} он был " \
               "единственным допущенным — весами это не лечится, надо расширять пул " \
               "(ослабить banks или limit_amount_max у остальных)."
      end

      "#{provider.name}: отклонение #{gap} п.п. при свободных лимитах — поднять вес " \
        "traffic_share в config/scoring.yml (сейчас #{result.config.weight('traffic_share')})."
    end

    def fallback_advice
      "#{decisions.count(&:fallback)} заявок ушли в fallback — расширить пул: ослабить " \
        "banks или limit_amount_max хотя бы у одного провайдера."
    end

    # --- мелочи -------------------------------------------------------------

    def provider_name(decision)
      decision.provider ? decision.provider.name : SELF_PROVIDER
    end

    # «1 заявка», «2 заявки», «5 заявок» — отчёт читает человек, и «1 заявок» в нём
    # выглядит ровно так же небрежно, как оно и есть.
    def plural(count, one, few, many)
      remainder100 = count.abs % 100
      remainder10 = count.abs % 10

      form = if remainder100.between?(11, 14) then many
             elsif remainder10 == 1 then one
             elsif remainder10.between?(2, 4) then few
             else many
             end

      "#{count} #{form}"
    end

    def tally(values)
      values.each_with_object(Hash.new(0)) { |value, memo| memo[value] += 1 }
            .sort_by { |_, count| -count }.to_h
    end

    def deviation(actual, target)
      target.nil? ? nil : round1(actual - target)
    end

    def percent(part, whole)
      return nil if whole.nil? || whole.zero? || whole == Float::INFINITY

      round1(part * 100.0 / whole)
    end

    def round1(value)
      value.to_f.round(1)
    end
  end
end
