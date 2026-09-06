require "json"

require_relative "spec_helper"

# Сверка с данными и эталоном организаторов (data/). Валидатор scripts/validate_10.rb
# проверяет только итоговый selected_provider; здесь дополнительно фиксируем сам
# состав допущенного пула — если фильтры разойдутся с эталоном, тест скажет, на какой
# заявке и по какому провайдеру.
RSpec.describe "hard-фильтры на данных организаторов" do
  DATA_DIR = File.expand_path("../data", __dir__)

  def data(filename)
    JSON.parse(File.read(File.join(DATA_DIR, filename)))
  end

  let(:reference) { data("reference_decisions.json") }
  let(:providers) { Routing::DataLoader.providers(File.join(DATA_DIR, "providers.json")).items }
  let(:operations) { Routing::DataLoader.operations(File.join(DATA_DIR, "operations_queue_10.json")).items }

  # Эталон перечисляет допустимых провайдеров без учёта stateful-лимитов,
  # поэтому и сверяем на чистом стартовом состоянии, по одной заявке за раз.
  def eligible_names(operation)
    state = Routing::RoutingState.new(providers)
    pool = Routing::Router.routable(providers)
    Routing::HardConstraints.eligible(pool, operation, state).eligible.map(&:name)
  end

  it "читает providers.json и очередь без ошибок разбора" do
    loaded_providers = Routing::DataLoader.providers(File.join(DATA_DIR, "providers.json"))
    loaded_queue = Routing::DataLoader.operations(File.join(DATA_DIR, "operations_queue_10.json"))

    expect(loaded_providers.errors).to be_empty
    expect(loaded_queue.errors).to be_empty
    expect(loaded_providers.items.map(&:name)).to include("vipay", "payflow", "quickpay", "spacepayments")
  end

  it "допускает ровно тех провайдеров, что перечислены в эталоне" do
    reference["eligible_providers"].each do |operation_id, expected|
      operation = operations.find { |op| op.id == operation_id }
      expect(operation).not_to be_nil, "в очереди нет #{operation_id}"
      expect(eligible_names(operation)).to eq(expected), operation_id
    end
  end

  it "исключает провайдеров ровно с теми причинами, что ждёт эталон" do
    reference["skip_reasons_expected"].each do |operation_id, expected_skips|
      operation = operations.find { |op| op.id == operation_id }
      state = Routing::RoutingState.new(providers)
      pool = Routing::Router.routable(providers)
      rejections = Routing::HardConstraints.eligible(pool, operation, state).rejections
      actual = rejections.to_h { |attempt| [attempt.provider, attempt.reason] }

      expected_skips.each do |provider_name, expected_reason|
        expect(actual[provider_name]).to eq(expected_reason), "#{operation_id}/#{provider_name}"
      end
    end
  end

  describe "полный прогон очереди" do
    # Профиль priority_only отдаёт весь вес фактору priority, то есть повторяет выбор
    # «первый по приоритету из допущенных» — прогон без влияния остальных soft-целей.
    let(:decisions) do
      Routing::Pipeline.run(
        queue_path: File.join(DATA_DIR, "operations_queue_10.json"),
        providers_path: File.join(DATA_DIR, "providers.json"),
        profile: "priority_only"
      ).decisions
    end

    it "принимает решение по каждой заявке, ровно с одним selected" do
      expect(decisions.size).to eq(operations.size)
      decisions.each do |decision|
        selected = decision.attempts.reject(&:skipped?)
        expect(selected.size).to eq(1), "#{decision.operation.id}: selected #{selected.size}"
      end
    end

    it "выбирает провайдера из детерминированных кейсов эталона" do
      required = reference["deterministic_cases"].to_h { |c| [c["operation_id"], c["required_provider"]] }

      decisions.each do |decision|
        expected = required[decision.operation.id]
        next unless expected

        expect(decision.provider.name).to eq(expected), decision.operation.id
      end
    end

    it "никогда не отдаёт заявку провайдеру, у которого сумма вне диапазона" do
      by_name = providers.to_h { |provider| [provider.name, provider] }

      decisions.reject(&:fallback).each do |decision|
        provider = by_name.fetch(decision.provider.name)
        expect(decision.operation.amount)
          .to be_between(provider.limit_amount_min, provider.limit_amount_max),
              "#{decision.operation.id}: #{decision.operation.amount} вне #{provider.name}"
      end
    end
  end
end
