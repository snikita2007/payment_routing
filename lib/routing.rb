require_relative "routing/errors"
require_relative "routing/attempt"
require_relative "routing/provider"
require_relative "routing/operation"
require_relative "routing/routing_state"
require_relative "routing/hard_constraints"
require_relative "routing/scoring_config"
require_relative "routing/provider_overrides"
require_relative "routing/conversion_stats"
require_relative "routing/factors"
require_relative "routing/result_simulator"
require_relative "routing/soft_scorer"
require_relative "routing/router"

module Routing
  # Провайдер последней инстанции: если внешний пул пуст, заявка уходит сюда.
  SELF_PROVIDER = "spacepayments".freeze
end
