RSpec.describe Routing::SoftScorer do
  def config_with(weights, extra = {})
    Routing::ScoringConfig.new(
      { "profile" => "test", "profiles" => { "test" => { "weights" => weights } } }.merge(extra)
    )
  end

  # Один провайдер лучше по конверсии, другой — по позиции в каскаде.
  # Кто победит, решают веса, а не код.
  let(:converter) { build_provider("converter", priority: 3, conversion_24h: 0.95, traffic_percentage: 50) }
  let(:cascader) { build_provider("cascader", priority: 1, conversion_24h: 0.50, traffic_percentage: 50) }
  let(:pool) { [converter, cascader] }
  let(:state) { build_state(pool) }
  let(:operation) { build_operation }

  describe "#rank" do
    it "ставит первым провайдера с наибольшим скором" do
      scorer = described_class.new(config: config_with("conversion" => 1.0))
      ranked = scorer.rank(pool, operation, state)

      expect(ranked.map(&:name)).to eq(%w[converter cascader])
      expect(ranked.first.score).to be > ranked.last.score
    end

    # Это и есть проверка требования «параметры меняются без переработки логики»:
    # тот же пул, та же заявка, тот же код — другой конфиг, другой победитель.
    it "смена весов в конфиге разворачивает выбор" do
      by_conversion = described_class.new(config: config_with("conversion" => 1.0))
      by_priority = described_class.new(config: config_with("priority" => 1.0))

      expect(by_conversion.rank(pool, operation, state).first.name).to eq("converter")
      expect(by_priority.rank(pool, operation, state).first.name).to eq("cascader")
    end

    it "фактор с нулевым весом в расчёт не идёт вовсе" do
      scorer = described_class.new(config: config_with("conversion" => 1.0, "priority" => 0.0))
      factors = scorer.rank(pool, operation, state).first.contributions.map(&:factor)

      expect(factors).to eq(["conversion"])
    end

    it "не трогает состояние" do
      scorer = described_class.new(config: config_with("conversion" => 1.0))

      expect { scorer.rank(pool, operation, state) }
        .not_to change { [state.total_routed_count, state.in_progress_count(converter)] }
    end
  end

  describe "разрешение ничьей" do
    let(:twins) do
      [build_provider("beta", priority: 2, conversion_24h: 0.5),
       build_provider("alpha", priority: 1, conversion_24h: 0.5)]
    end

    it "при равных скорах решает priority" do
      scorer = described_class.new(
        config: config_with({ "conversion" => 1.0 }, "tie_break" => %w[priority_asc input_order])
      )
      ranked = scorer.rank(twins, operation, build_state(twins))

      expect(ranked.map(&:name)).to eq(%w[alpha beta])
    end

    # sort_by в Ruby нестабильна: без явного последнего звена порядок при равных
    # ключах не определён, и прогон на тех же данных может дать разный ответ.
    it "порядок пула — последнее звено, даже если его не написали в конфиге" do
      scorer = described_class.new(
        config: config_with({ "conversion" => 1.0 }, "tie_break" => [])
      )
      ranked = scorer.rank(twins, operation, build_state(twins))

      expect(ranked.map(&:name)).to eq(%w[beta alpha])
    end

    it "выдаёт один и тот же порядок при повторных вызовах" do
      scorer = described_class.new(config: config_with("conversion" => 1.0))
      results = Array.new(5) { scorer.rank(twins, operation, build_state(twins)).map(&:name) }

      expect(results.uniq.size).to eq(1)
    end
  end

  describe "объяснимость" do
    let(:scorer) do
      described_class.new(config: config_with("conversion" => 0.7, "priority" => 0.3))
    end

    it "каждое слагаемое несёт своё объяснение" do
      scored = scorer.score(converter, operation, state)

      expect(scored.contributions.map(&:factor)).to contain_exactly("conversion", "priority")
      expect(scored.contributions.map(&:explain)).to all(be_a(String))
      expect(scored.contributions.map(&:explain)).to all(satisfy { |text| !text.empty? })
    end

    it "в details попадает и сумма, и что на неё повлияло сильнее всего" do
      details = scorer.score(converter, operation, state).details(2)

      expect(details).to match(/score \d\.\d{3} = /)
      expect(details).to include("conversion 0.70")
    end

    # Отрицательный вклад решает исход не реже положительного: провайдер, перебравший
    # целевую долю, проигрывает именно из-за минуса. Сортировка по модулю, а не по значению.
    it "топ факторов считается по модулю вклада, иначе решающий минус не покажется" do
      over = build_provider("over", traffic_percentage: 10, conversion_24h: 0.8)
      state = build_state(over)
      9.times { state.record_routed(over, 1000) }

      scored = described_class
               .new(config: config_with("traffic_share" => 0.5, "conversion" => 0.5))
               .score(over, operation, state)

      expect(scored.top(1).first.factor).to eq("traffic_share")
      expect(scored.top(1).first.contribution).to be < 0
    end
  end

  describe "штраф за свежие сбои" do
    # На боевой очереди из 10 заявок штраф ничего не переворачивает: единственные заявки
    # с зазором меньше 0.12 — первые две, а к этому моменту ни один исход ещё не пришёл
    # (первый известен только на 51-й секунде). Поэтому работоспособность фактора
    # проверяем на сценарии, где зазор узкий, а сбой уже случился.
    let(:base) { Time.parse("2026-07-30T09:00:00+03:00") }
    let(:leader) { build_provider("leader", priority: 1, conversion_24h: 0.80) }
    let(:runner_up) { build_provider("runner_up", priority: 1, conversion_24h: 0.78) }
    let(:pair) { [leader, runner_up] }

    let(:scorer) do
      described_class.new(
        config: config_with(
          { "conversion" => 0.5, "recent_failure" => 0.5 },
          "recent_failure" => { "half_life_sec" => 45, "prior_strength" => 1 }
        )
      )
    end

    let(:later) { build_operation(created_at: (base + 10).iso8601) }

    it "без сбоев впереди тот, кто лучше по конверсии" do
      expect(scorer.rank(pair, later, build_state(pair)).first.name).to eq("leader")
    end

    it "свежий сбой у лидера отдаёт заявку второму" do
      state = build_state(pair)
      state.record_outcome(leader, at: base, failure: true)

      expect(scorer.rank(pair, later, state).first.name).to eq("runner_up")
    end

    it "давний сбой уже не переворачивает выбор" do
      state = build_state(pair)
      state.record_outcome(leader, at: base - 600, failure: true)

      expect(scorer.rank(pair, later, state).first.name).to eq("leader")
    end

    it "штраф виден в разборе как отрицательный вклад" do
      state = build_state(pair)
      state.record_outcome(leader, at: base, failure: true)
      contribution = scorer.score(leader, later, state)
                           .contributions.find { |item| item.factor == "recent_failure" }

      expect(contribution.contribution).to be < 0
      expect(contribution.explain).to match(/свежие сбои/)
    end
  end

  describe "профиль priority_only" do
    let(:providers) do
      Routing::DataLoader.providers(File.expand_path("../data/providers.json", __dir__)).items
    end

    # Заглушка, которая была до скорера, — это min_by(priority). Профиль должен повторять её
    # ровно, иначе «старое поведение выражается конфигом» остаётся словами.
    it "повторяет прежний выбор min_by(priority)" do
      pool = Routing::Router.routable(providers)
      scorer = described_class.new(config: Routing::ScoringConfig.load(nil, profile: "priority_only"))
      state = build_state(providers)

      expect(scorer.rank(pool, operation, state).first.provider)
        .to eq(pool.min_by { |provider| provider.priority || Float::INFINITY })
    end
  end
end
