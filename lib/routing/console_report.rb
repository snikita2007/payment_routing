require_relative "format"
require_relative "result_simulator"

module Routing
  # Сводка прогона в консоль: распределение против целевого, исходы, причины отсева,
  # загрузка лимитов.
  #
  # Читает готовый Pipeline::Result и ничего не считает заново — цифры в сводке и цифры
  # в routing_decisions.json обязаны быть одними и теми же.
  #
  # Это диагностика для человека за клавиатурой, а не сдаваемый артефакт:
  # routing_report_test.json собирается отдельно и в другом формате.
  class ConsoleReport
    attr_reader :result, :io

    def initialize(result, io: $stdout)
      @result = result
      @io = io
    end

    def print
      print_header
      print_distribution
      print_outcomes
      print_skip_reasons
      print_utilization
      print_totals
    end

    private

    def decisions
      result.decisions
    end

    def state
      result.state
    end

    def print_header
      io.puts "\nПрофиль: #{result.config.profile_name}   #{weights_line}"
      io.puts "Заявок обработано: #{decisions.size}"
    end

    def weights_line
      result.config.weights.reject { |_, value| value.to_f.zero? }
            .map { |key, value| "#{key} #{format('%.2f', value)}" }
            .join("  ")
    end

    def print_distribution
      io.puts "\nРаспределение против целевого:"
      io.puts format("  %-14s %5s %8s %8s %8s   %8s %8s %8s",
                     "провайдер", "шт", "факт%", "цель%", "Δ", "объём%", "цель%", "Δ")

      result.external.each do |provider|
        io.puts format("  %-14s %5d %7.1f%% %s   %7.1f%% %s",
                       provider.name, state.routed_count(provider),
                       state.count_share_pct(provider),
                       target_columns(state.count_share_pct(provider), provider.traffic_percentage),
                       state.volume_share_pct(provider),
                       target_columns(state.volume_share_pct(provider), provider.volume_share_pct))
      end

      io.puts format("  %-14s %5d", "итого", state.total_routed_count)
      print_soft_selection
    end

    # Незаданная цель и цель, равная нулю, — разные вещи, и в сводке это должно быть видно:
    # иначе отклонение от несуществующей цели читается как реальный перебор.
    def target_columns(actual, target)
      return format("%8s %7s", "—", "—") if target.nil?

      format("%7.1f%% %+7.1f", target.to_f, actual - target.to_f)
    end

    # Сколько решений реально принял скорер, а сколько было предопределено фильтрами.
    # Без этой строки распределение читается как заслуга скоринга, хотя часть заявок
    # выбора не имела вовсе.
    def print_soft_selection
      contested = decisions.count { |decision| decision.ranked.size > 1 }
      forced = decisions.count { |decision| decision.ranked.size == 1 }
      io.puts "\n  скорер выбирал: #{contested}, предопределено фильтрами: #{forced}, " \
              "fallback: #{decisions.count(&:fallback)}"
    end

    def print_outcomes
      outcomes = decisions.map(&:outcome).compact
      return if outcomes.empty?

      io.puts "\nСимулированные исходы:"
      ResultSimulator::STATUSES.each do |status|
        matching = outcomes.select { |outcome| outcome.status == status }
        next if matching.empty?

        latency = matching.sum(&:latency_sec).fdiv(matching.size)
        io.puts format("  %-10s %3d  %5s%%   средняя задержка %d с",
                       status, matching.size, Format.share(matching.size, outcomes.size),
                       latency.round)
      end

      io.puts "  сбоев по провайдерам: #{failures_line}"
    end

    def failures_line
      by_provider = Hash.new { |hash, key| hash[key] = [0, 0] }

      decisions.each do |decision|
        next unless decision.outcome

        name = decision.provider ? decision.provider.name : SELF_PROVIDER
        by_provider[name][0] += 1
        by_provider[name][1] += 1 if decision.outcome.failure?
      end

      by_provider.map { |name, (total, bad)| "#{name} #{bad}/#{total}" }.join(", ")
    end

    def print_skip_reasons
      reasons = Hash.new(0)
      decisions.each do |decision|
        decision.attempts.select(&:skipped?).each { |attempt| reasons[attempt.reason] += 1 }
      end
      return if reasons.empty?

      io.puts "\nПричины отсева:"
      reasons.sort_by { |_, count| -count }.each do |reason, count|
        io.puts format("  %-26s %d", reason, count)
      end
    end

    def print_utilization
      io.puts "\nЗагрузка дневных лимитов на конец прогона:"
      result.providers.each do |provider|
        limit = provider.daily_amount_limit
        used = state.daily_turnover(provider)
        unlimited = limit == Float::INFINITY

        io.puts format("  %-14s %13s / %-13s %7s",
                       provider.name, Format.money(used),
                       unlimited ? "без лимита" : Format.money(limit),
                       unlimited ? "—" : "#{Format.share(used, limit)}%")
      end
    end

    def print_totals
      fallbacks = decisions.count(&:fallback)
      io.puts "\nFallback на #{SELF_PROVIDER}: #{fallbacks} (#{Format.share(fallbacks, decisions.size)}%)"
      io.puts "Сумма очереди: #{Format.money(result.operations.sum(&:amount))} ₽"
    end
  end
end
