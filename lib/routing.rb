# Точка входа библиотеки. Порядок require повторяет порядок конвейера:
# данные → состояние → hard-фильтры → скоринг → маршрутизация → вывод.

require_relative "routing/errors"
require_relative "routing/format"

# Данные: провайдеры, заявки, история, свои поля поверх providers.json.
require_relative "routing/attempt"
require_relative "routing/provider"
require_relative "routing/operation"
require_relative "routing/data_loader"
require_relative "routing/provider_overrides"
require_relative "routing/conversion_stats"

# Состояние по ходу очереди и допуск провайдеров к заявке.
require_relative "routing/routing_state"
require_relative "routing/hard_constraints"

# Ранжирование допущенных и симуляция исхода.
require_relative "routing/scoring_config"
require_relative "routing/factors"
require_relative "routing/result_simulator"
require_relative "routing/soft_scorer"
require_relative "routing/router"

# Прикладной слой: сборка конвейера и вывод результата.
require_relative "routing/pipeline"
require_relative "routing/decisions_file"
require_relative "routing/report_builder"
require_relative "routing/console_report"

module Routing
  # Провайдер последней инстанции: если внешний пул пуст, заявка уходит сюда.
  SELF_PROVIDER = "spacepayments".freeze
end
