require_relative "routing/errors"
require_relative "routing/attempt"
require_relative "routing/provider"
require_relative "routing/operation"
require_relative "routing/routing_state"
require_relative "routing/hard_constraints"

module Routing
  # Провайдер последней инстанции: если внешний пул пуст, заявка уходит сюда.
  SELF_PROVIDER = "spacepayments".freeze
end
