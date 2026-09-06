module Routing
  # Форматирование чисел для строк, которые читает человек: details в attempts,
  # объяснения факторов, сводка в консоли.
  #
  # Держим в одном месте, потому что раньше эта же горстка правил лежала копиями
  # в факторах, в hard-проверках и в скрипте прогона — и «100000.0» в отчёте
  # зависело от того, чей именно fmt до него дотянулся.
  module Format
    INFINITY_SIGN = "∞".freeze
    # NaN в отчёте — не ноль и не «0.00»: это «посчитать не вышло», и выглядеть
    # оно должно соответственно, а не правдоподобным числом.
    NOT_A_NUMBER = "—".freeze

    module_function

    # Число без лишнего хвоста: 100000.0 → "100000", 1.5 → "1.50", ∞ → "∞".
    def number(value, precision: 2)
      return value.to_s unless value.is_a?(Numeric)
      return NOT_A_NUMBER if value.respond_to?(:nan?) && value.nan?
      return INFINITY_SIGN if value == Float::INFINITY
      return "-#{INFINITY_SIGN}" if value == -Float::INFINITY

      value == value.to_i ? value.to_i.to_s : format("%.#{precision}f", value)
    end

    # Готовая доля в процентах: 12.34 → "12.3%".
    def pct(value)
      format("%.1f%%", value)
    end

    # Доля part от whole в процентах, без знака «%» — в таблицах он печатается отдельно.
    # Неопределённое отношение (знаменателя нет, он нулевой или бесконечный) — это «0.0»,
    # а не деление на ноль посреди печати отчёта.
    def share(part, whole)
      return "0.0" if whole.nil? || whole.zero? || whole == Float::INFINITY

      format("%.1f", part * 100.0 / whole)
    end

    # Деньги с пробелом на разряд: 3215000 → "3 215 000".
    def money(value)
      return number(value) unless value.is_a?(Numeric) && value.finite?

      digits = value.round.abs.to_s.reverse.scan(/\d{1,3}/).join(" ").reverse
      value.negative? ? "-#{digits}" : digits
    end
  end
end
