require "json"
require "stringio"
require "tmpdir"

require_relative "../bin/route"

# Полный конвейер на данных организаторов: hard-фильтры → скоринг → решение.
# real_data_spec.rb проверяет сами фильтры; здесь — то, что добавил скорер.
RSpec.describe "маршрутизация со скорингом" do
  def data_file(name)
    File.expand_path("../data/#{name}", __dir__)
  end

  def silently
    out = $stdout
    err = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
  ensure
    $stdout = out
    $stderr = err
  end

  def route(profile: nil)
    Dir.mktmpdir do |dir|
      out = File.join(dir, "decisions.json")
      decisions = silently do
        Route.run(queue_path: data_file("operations_queue_10.json"),
                  providers_path: data_file("providers.json"),
                  out_path: out, profile: profile, quiet: true)
      end
      [decisions, JSON.parse(File.read(out))]
    end
  end

  let(:reference) { JSON.parse(File.read(data_file("reference_decisions.json"))) }
  let(:run) { route }
  let(:decisions) { run.first }
  let(:payload) { run.last }

  it "принимает решение по каждой заявке, ровно с одним selected" do
    expect(decisions.size).to eq(10)

    decisions.each do |decision|
      selected = decision.attempts.reject(&:skipped?)
      expect(selected.size).to eq(1), "#{decision.operation.id}: selected #{selected.size}"
    end
  end

  it "держит детерминированные кейсы эталона" do
    required = reference["deterministic_cases"].to_h { |item| [item["operation_id"], item["required_provider"]] }

    decisions.each do |decision|
      expected = required[decision.operation.id]
      next unless expected

      expect(decision.provider.name).to eq(expected), decision.operation.id
    end
  end

  # Валидатор организаторов требует, чтобы в attempts был каждый рассмотренный провайдер,
  # а жюри отдельно считает баллы за причины по невыбранным. Проигравший по скору
  # обязан остаться в списке, а не исчезнуть.
  it "перечисляет в attempts всех допущенных, а не только победителя" do
    decisions.reject(&:fallback).each do |decision|
      names = decision.attempts.map(&:provider)
      expect(names).to include(*decision.ranked.map(&:name)), decision.operation.id
    end
  end

  it "у проигравших по скору причина и details говорят, кому и насколько уступили" do
    outscored = decisions.flat_map(&:attempts).select { |attempt| attempt.reason == "lower_score" }

    expect(outscored).not_to be_empty
    expect(outscored.map(&:details)).to all(match(/score .* — ниже, чем у \w+ \(\d\.\d{3}\)/))
  end

  it "у выбранного в details виден и скор, и решающий фактор" do
    contested = decisions.find { |decision| decision.ranked.size > 1 }
    selected = contested.attempts.find { |attempt| !attempt.skipped? }

    expect(selected.reason).to eq("highest_weighted_score")
    expect(selected.details).to match(/score \d\.\d{3} = /)
  end

  it "когда допущен ровно один, причина остаётся эталонной" do
    forced = decisions.find { |decision| decision.ranked.size == 1 }
    selected = forced.attempts.find { |attempt| !attempt.skipped? }

    expect(selected.reason).to eq("only_eligible_provider")
  end

  it "пишет файл в формате, который ждёт валидатор" do
    expect(payload.size).to eq(10)
    expect(payload.map { |item| item["operation_id"] }).to eq((101..110).map { |n| "op_#{n}" })

    payload.each do |item|
      expect(item.keys).to include("operation_id", "selected_provider", "attempts")
      expect(item["attempts"].map { |a| a["decision"] }.uniq - %w[selected skipped]).to be_empty
    end
  end

  # Если бы скорер не влиял на исход, весь слой был бы декорацией. Профиль priority_only
  # выключает soft-цели, и хотя бы на одной заявке ответ обязан разойтись.
  it "меняет исход по сравнению с выбором только по priority" do
    with_soft = route.first.map { |decision| decision.provider&.name }
    without_soft = route(profile: "priority_only").first.map { |decision| decision.provider&.name }

    expect(with_soft).not_to eq(without_soft)
  end

  describe "состояние после прогона" do
    it "считает розданное по каждому провайдеру и в сумме" do
      state = silently do
        providers = Routing::ProviderOverrides.load
                                              .apply(Routing::DataLoader.providers(data_file("providers.json")).items)
                                              .providers
        operations = Routing::DataLoader.operations(data_file("operations_queue_10.json")).items
        scorer = Routing::SoftScorer.new(config: Routing::ScoringConfig.load,
                                         stats: Routing::ConversionStats.load)
        state = Routing::RoutingState.new(providers)
        Routing::Router.new(providers: Routing::Router.routable(providers), scorer: scorer)
                       .run(operations, state)
        state
      end

      expect(state.total_routed_count).to eq(10)
      expect(state.total_routed_amount).to eq(385_800)
      expect(state.count_share_pct("vipay") + state.count_share_pct("payflow") +
             state.count_share_pct("quickpay")).to be_within(1e-9).of(100.0)
    end

    it "оверлей проставил поля, которых нет в providers.json" do
      providers = Routing::ProviderOverrides.load
                                            .apply(Routing::DataLoader.providers(data_file("providers.json")).items)
                                            .providers
      vipay = providers.find { |provider| provider.name == "vipay" }

      expect(vipay.volume_share_pct).to eq(35)
      expect(vipay.daily_turnover_min).to eq(3_300_000)
      # Поле из данных оверлей не перебивает.
      expect(vipay.traffic_percentage).to eq(40)
    end
  end

  describe "fallback" do
    let(:providers) do
      Routing::DataLoader.providers(File.expand_path("../data/providers.json", __dir__)).items
    end

    # Целевые доли заданы по внешним провайдерам и дают в сумме 100. Заявка, ушедшая
    # в последнюю инстанцию, не должна разбавлять этот знаменатель — иначе недобор
    # у всех останется положительным до конца очереди.
    it "уходит на self-provider и не попадает в знаменатель долей" do
      scorer = Routing::SoftScorer.new(config: Routing::ScoringConfig.load)
      state = Routing::RoutingState.new(providers)
      router = Routing::Router.new(providers: Routing::Router.routable(providers), scorer: scorer)

      huge = Routing::Operation.from_hash(
        "operation_id" => "op_huge", "amount" => 900_000_000, "bank" => "sberbank"
      )
      decision = router.route(huge, state)

      expect(decision.fallback).to be(true)
      expect(decision.attempts.last.provider).to eq(Routing::SELF_PROVIDER)
      expect(decision.attempts.last.reason).to eq("fallback_self_provider")
      expect(state.total_routed_count).to eq(0)
      expect(state.routed_count(Routing::SELF_PROVIDER)).to eq(1)
    end
  end
end
