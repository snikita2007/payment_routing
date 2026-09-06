RSpec.describe Routing::Factors do
  def factor(klass, **options)
    klass.new(options: stringify(options), epsilon: 1.0e-06)
  end

  describe Routing::Factors::TrafficShareFactor do
    let(:vipay) { build_provider("vipay", traffic_percentage: 40) }
    let(:quickpay) { build_provider("quickpay", traffic_percentage: 25) }

    it "на пустом состоянии различает цель 40% и цель 25%" do
      state = build_state([vipay, quickpay])
      subject = factor(described_class, mode: "expected")

      expect(subject.score(vipay, build_operation, state)).to be_within(1e-9).of(0.40)
      expect(subject.score(quickpay, build_operation, state)).to be_within(1e-9).of(0.25)
    end

    # Ради этого и добавлен режим expected: буквальная формула на первой заявке
    # выдаёт единицу всем сразу и о целях не говорит ничего.
    it "в режиме ratio на пустом состоянии одинаково слепа к обеим целям" do
      state = build_state([vipay, quickpay])
      subject = factor(described_class, mode: "ratio")

      expect(subject.score(vipay, build_operation, state)).to be_within(1e-6).of(1.0)
      expect(subject.score(quickpay, build_operation, state)).to be_within(1e-6).of(1.0)
      expect(subject.score(vipay, build_operation, state))
        .to be_within(1e-6).of(subject.score(quickpay, build_operation, state))
    end

    it "уходит в минус, когда провайдер перебрал свою долю" do
      state = build_state([vipay, quickpay])
      6.times { state.record_routed(vipay, 1000) }
      state.record_routed(quickpay, 1000)

      value = factor(described_class, mode: "ratio").score(vipay, build_operation, state)
      expect(value).to be < 0
    end

    it "молчит, когда целевая доля не задана" do
      provider = build_provider("noname")
      state = build_state(provider)

      assessment = factor(described_class).assess(provider, build_operation, state)
      expect(assessment.value).to eq(0.0)
      expect(assessment.explain).to include("traffic_percentage не задан")
    end

    it "нулевую цель отличает от незаданной: получивший трафик уходит в −1" do
      provider = build_provider("zero", traffic_percentage: 0)
      state = build_state(provider)
      state.record_routed(provider, 1000)

      expect(factor(described_class, mode: "ratio").score(provider, build_operation, state)).to eq(-1.0)
    end
  end

  describe Routing::Factors::VolumeShareFactor do
    let(:vipay) { build_provider("vipay", volume_share_pct: 60) }
    let(:quickpay) { build_provider("quickpay", volume_share_pct: 40) }

    it "считает недобор в деньгах, а не в штуках" do
      state = build_state([vipay, quickpay])
      state.record_routed(quickpay, 100_000)
      operation = build_operation(amount: 10_000)

      expect(factor(described_class).score(vipay, operation, state)).to be > 0
      expect(factor(described_class).score(quickpay, operation, state)).to be < 0
    end

    it "молчит без volume_share_pct" do
      provider = build_provider("noname")
      expect(factor(described_class).score(provider, build_operation, build_state(provider))).to eq(0.0)
    end
  end

  describe Routing::Factors::ConversionFactor do
    let(:state) { build_state(provider) }

    context "источник declared" do
      let(:provider) { build_provider("vipay", conversion_24h: 0.87) }

      it "берёт conversion_24h как есть, когда это доля" do
        value = factor(described_class, source: "declared").score(provider, build_operation, state)
        expect(value).to be_within(1e-9).of(0.87)
      end

      it "то же поле в процентах приводит к доле" do
        percent = build_provider("vipay", conversion_24h: 87)
        value = factor(described_class, source: "declared").score(percent, build_operation, build_state(percent))
        expect(value).to be_within(1e-9).of(0.87)
      end

      # Вероятность — не цель: незнание здесь честнее выразить серединой, а ноль
      # означал бы «конверсия нулевая», то есть очень сильное утверждение.
      it "без conversion_24h берёт середину, а не ноль" do
        blank = build_provider("blank")
        value = factor(described_class, source: "declared").score(blank, build_operation, build_state(blank))
        expect(value).to eq(0.5)
      end

      # Мусор в данных не должен выносить фактор за его бюджет весов:
      # без клипа 150 стало бы 1.5, и слагаемое с весом 0.30 внесло бы 0.45.
      it "не выпускает значение за пределы [0, 1]" do
        broken = build_provider("vipay", conversion_24h: 150)
        value = factor(described_class, source: "declared").score(broken, build_operation, build_state(broken))
        expect(value).to eq(1.0)
      end
    end

    context "источник history" do
      let(:provider) { build_provider("vipay", conversion_24h: 0.87) }

      let(:stats) do
        rows = Array.new(20) do |i|
          {
            "payment_system" => "vipay", "bank" => "sberbank", "amount" => "10000",
            "card_brand" => "", "status" => i < 18 ? "approved" : "rejected", "latency_sec" => "40"
          }
        end
        Routing::ConversionStats.new(rows)
      end

      it "считает по истории, а не по заявленному полю" do
        subject = described_class.new(options: { "source" => "history" }, epsilon: 1.0e-06, stats: stats)
        assessment = subject.assess(provider, build_operation(bank: "sberbank", amount: 10_000), state)

        expect(assessment.value).to be_within(0.05).of(0.9)
        expect(assessment.explain).to include("по истории")
      end
    end

    context "источник blend" do
      let(:provider) { build_provider("vipay", conversion_24h: 0.9) }

      it "смешивает историю и заявленное в заданной пропорции" do
        stats = Routing::ConversionStats.new([])
        subject = described_class.new(
          options: { "source" => "blend", "blend_history_weight" => 0.5 },
          epsilon: 1.0e-06, stats: stats
        )

        # Пустая история отдаёт 0.5, заявленная — 0.9; пополам это 0.7.
        expect(subject.score(provider, build_operation, state)).to be_within(1e-9).of(0.7)
      end
    end
  end

  describe Routing::Factors::PriorityFactor do
    it "переводит позицию в каскаде в 1/priority" do
      subject = factor(described_class)
      first = build_provider("a", priority: 1)
      second = build_provider("b", priority: 2)

      expect(subject.score(first, build_operation, build_state(first))).to eq(1.0)
      expect(subject.score(second, build_operation, build_state(second))).to eq(0.5)
    end

    it "молчит без priority и при неположительном priority" do
      subject = factor(described_class)
      blank = build_provider("blank")
      zero = build_provider("zero", priority: 0)

      expect(subject.score(blank, build_operation, build_state(blank))).to eq(0.0)
      expect(subject.score(zero, build_operation, build_state(zero))).to eq(0.0)
    end
  end

  describe Routing::Factors::TurnoverMinFactor do
    it "тем выше, чем больше недобор обязательства" do
      provider = build_provider("vipay", daily_turnover_min: 1_000_000, daily_approved_amount: 400_000)
      value = factor(described_class).score(provider, build_operation, build_state(provider))

      expect(value).to be_within(1e-6).of(0.6)
    end

    it "гаснет, как только минимум набран" do
      provider = build_provider("vipay", daily_turnover_min: 1_000_000, daily_approved_amount: 1_200_000)
      assessment = factor(described_class).assess(provider, build_operation, build_state(provider))

      expect(assessment.value).to eq(0.0)
      expect(assessment.explain).to include("набран")
    end

    it "молчит без daily_turnover_min" do
      provider = build_provider("vipay")
      expect(factor(described_class).score(provider, build_operation, build_state(provider))).to eq(0.0)
    end
  end

  describe Routing::Factors::LoadFactor do
    it "без лимитов считает провайдера полностью свободным" do
      provider = build_provider("vipay")
      expect(factor(described_class).score(provider, build_operation, build_state(provider))).to eq(1.0)
    end

    it "берёт самый напряжённый из двух лимитов" do
      provider = build_provider(
        "vipay",
        in_progress_count_limit: 10, in_progress_count: 2,
        in_progress_amount_limit: 1000, in_progress_amount: 800
      )

      # По количеству загружен на 20%, по сумме на 80% — решает вторая.
      expect(factor(described_class).score(provider, build_operation, build_state(provider)))
        .to be_within(1e-9).of(0.2)
    end

    it "нулевой лимит — это полная загрузка, а не деление на ноль" do
      provider = build_provider("vipay", in_progress_count_limit: 0)
      expect(factor(described_class).score(provider, build_operation, build_state(provider))).to eq(0.0)
    end
  end

  describe Routing::Factors::SpeedFactor do
    it "чем быстрее провайдер, тем выше оценка" do
      provider = build_provider("vipay", avg_latency_sec: 60)
      value = factor(described_class, latency_scale_sec: 120).score(provider, build_operation, build_state(provider))

      expect(value).to be_within(1e-9).of(0.5)
    end

    it "медленнее шкалы — ноль, без ухода в минус" do
      provider = build_provider("vipay", avg_latency_sec: 300)
      expect(factor(described_class, latency_scale_sec: 120).score(provider, build_operation, build_state(provider)))
        .to eq(0.0)
    end

    it "нулевая шкала не обнуляет всех, а откатывается к дефолтной" do
      provider = build_provider("vipay", avg_latency_sec: 60)
      expect(factor(described_class, latency_scale_sec: 0).score(provider, build_operation, build_state(provider)))
        .to be > 0
    end

    it "без данных о времени молчит" do
      provider = build_provider("vipay")
      expect(factor(described_class).score(provider, build_operation, build_state(provider))).to eq(0.0)
    end
  end

  describe Routing::Factors::RecentFailureFactor do
    let(:provider) { build_provider("vipay") }
    let(:state) { build_state(provider) }
    let(:base) { Time.parse("2026-07-30T09:00:00+03:00") }

    def at(offset)
      build_operation(created_at: (base + offset).iso8601)
    end

    def fail_at(offset)
      state.record_outcome(provider, at: base + offset, failure: true)
    end

    it "без событий молчит и не даёт NaN" do
      assessment = factor(described_class).assess(provider, at(0), state)

      expect(assessment.value).to eq(0.0)
      expect(assessment.explain).to include("свежих сбоев нет")
    end

    it "свежий сбой уводит фактор в минус" do
      fail_at(0)
      expect(factor(described_class).score(provider, at(10), state)).to be < 0
    end

    it "успешные заявки штрафа не создают" do
      state.record_outcome(provider, at: base, failure: false)
      expect(factor(described_class).score(provider, at(10), state)).to eq(0.0)
    end

    # Ради этого фактор и вводился: недавний сбой должен весить больше давнего.
    it "сбой 20 секунд назад штрафует сильнее, чем сбой 4 минуты 50 секунд назад" do
      recent = build_state(provider)
      recent.record_outcome(provider, at: base - 20, failure: true)
      old = build_state(provider)
      old.record_outcome(provider, at: base - 290, failure: true)

      subject = factor(described_class, half_life_sec: 45)
      expect(subject.score(provider, at(0), recent).abs)
        .to be > subject.score(provider, at(0), old).abs * 5
    end

    it "период полураспада задаёт скорость забывания" do
      fail_at(0)
      short = factor(described_class, half_life_sec: 10).score(provider, at(60), state).abs
      long = factor(described_class, half_life_sec: 600).score(provider, at(60), state).abs

      expect(long).to be > short
    end

    # Исход заявки, отправленной 30 секунд назад с задержкой 50 секунд, ещё не пришёл.
    # Учитывать его — значит подглядывать в будущее и штрафовать за то, чего мы не знаем.
    it "не заглядывает вперёд: событие из будущего не учитывается" do
      fail_at(120)
      expect(factor(described_class).score(provider, at(60), state)).to eq(0.0)
      expect(factor(described_class).score(provider, at(121), state)).to be < 0
    end

    it "один сбой не выкручивает штраф на максимум" do
      fail_at(0)
      value = factor(described_class, half_life_sec: 45, prior_strength: 1).score(provider, at(0), state)

      expect(value).to be_within(1e-6).of(-0.5)
    end

    it "череда сбоев штрафует сильнее одного" do
      fail_at(0)
      one = factor(described_class).score(provider, at(1), state).abs
      3.times { |i| fail_at(i + 1) }
      many = factor(described_class).score(provider, at(5), state).abs

      expect(many).to be > one
    end

    it "не выходит за пределы [−1, 0]" do
      50.times { |i| fail_at(i) }
      value = factor(described_class).score(provider, at(50), state)

      expect(value).to be_between(-1.0, 0.0)
    end

    it "по умолчанию историческую долю сбоев в базу не берёт" do
      stats = Routing::ConversionStats.new(
        Array.new(20) { { "payment_system" => "vipay", "status" => "rejected", "bank" => "vtb",
                          "amount" => "1000", "card_brand" => "", "latency_sec" => "10" } }
      )
      subject = described_class.new(options: {}, epsilon: 1.0e-06, stats: stats)

      expect(subject.score(provider, at(0), state)).to eq(0.0)
    end

    it "с baseline: historical опирается на историю даже без свежих событий" do
      stats = Routing::ConversionStats.new(
        Array.new(20) { { "payment_system" => "vipay", "status" => "rejected", "bank" => "vtb",
                          "amount" => "1000", "card_brand" => "", "latency_sec" => "10" } }
      )
      subject = described_class.new(options: { "baseline" => "historical" }, epsilon: 1.0e-06, stats: stats)

      expect(subject.score(provider, at(0), state)).to be < -0.5
    end
  end

  describe "реестр" do
    it "знает все восемь факторов формулы" do
      expect(described_class.keys).to contain_exactly(
        "traffic_share", "volume_share", "conversion", "priority",
        "turnover_min", "load", "speed", "recent_failure"
      )
    end

    it "на неизвестное имя отвечает понятной ошибкой, а не молчанием" do
      expect { described_class.build("нет_такого") }
        .to raise_error(ArgumentError, /неизвестный фактор/)
    end
  end
end
