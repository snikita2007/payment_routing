require "json"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "routing"
require "routing/data_loader"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :defined
end

module SpecHelpers
  FIXTURES = File.expand_path("fixtures", __dir__)

  # Провайдер с разумными дефолтами: в тесте задаём только то поле, которое проверяем.
  # Ключ payment_system — как в боевом data/providers.json.
  def build_provider(name = "vipay", **fields)
    Routing::Provider.from_hash({ "payment_system" => name }.merge(stringify(fields)))
  end

  def build_operation(**fields)
    defaults = { "operation_id" => "op_1", "amount" => 10_000, "bank" => "sberbank" }
    Routing::Operation.from_hash(defaults.merge(stringify(fields)))
  end

  def build_state(providers, clock: -> { Time.at(0) })
    Routing::RoutingState.new(Array(providers), clock: clock)
  end

  def stringify(fields)
    fields.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value }
  end
end

RSpec.configure { |config| config.include SpecHelpers }
