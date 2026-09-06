RSpec.describe Routing::ResultSimulator do
  let(:provider) { build_provider("vipay", conversion_24h: 0.8, avg_latency_sec: 40) }
  let(:operation) { build_operation(created_at: "2026-07-30T09:00:00+03:00") }

  def simulator(**options)
    described_class.new(**{ stats: nil }.merge(options))
  end

  describe "детерминированность" do
    # Без этого нельзя ни сравнить два профиля, ни зафиксировать прогон тестом:
    # каждый запуск давал бы другой ответ.
    it "один и тот же seed даёт один и тот же исход" do
      first = simulator(seed: 42).simulate(provider, operation)
      second = simulator(seed: 42).simulate(provider, operation)

      expect(first.to_h).to eq(second.to_h)
    end

    it "разные seed дают разные прогоны" do
      statuses = (1..40).map do |seed|
        simulator(seed: seed).simulate(provider, build_operation(operation_id: "op_#{seed}")).status
      end

      expect(statuses.uniq.size).to be > 1
    end

    # String#hash в Ruby рандомизируется на каждый процесс, поэтому ключ считается FNV-1a.
    # Проверяем через отдельный процесс: внутри одного разницы было бы не видно.
    it "воспроизводится между запусками процесса, а не только внутри одного" do
      script = <<~RUBY
        $LOAD_PATH.unshift(#{File.expand_path("../lib", __dir__).inspect})
        require "routing"
        provider = Routing::Provider.from_hash("payment_system" => "vipay", "conversion_24h" => 0.8)
        operation = Routing::Operation.from_hash("operation_id" => "op_1", "amount" => 1000)
        print Routing::ResultSimulator.new(seed: 7).simulate(provider, operation).status
      RUBY

      results = Array.new(2) { IO.popen([RbConfig.ruby, "-e", script], &:read) }
      expect(results.uniq.size).to eq(1)
    end
  end

  describe "вероятность одобрения" do
    it "на большой выборке доля approved сходится к заданной" do
      lucky = build_provider("lucky", conversion_24h: 0.9)
      approved = (1..400).count do |i|
        simulator(seed: 1).simulate(lucky, build_operation(operation_id: "op_#{i}")).approved?
      end

      expect(approved / 400.0).to be_within(0.05).of(0.9)
    end

    it "без истории и без conversion_24h берёт нейтральную середину" do
      blank = build_provider("blank")
      expect(simulator.approve_probability(blank, operation)).to eq(0.5)
    end

    it "conversion_24h в процентах приводит к доле" do
      percent = build_provider("vipay", conversion_24h: 80)
      expect(simulator.approve_probability(percent, operation)).to be_within(1e-9).of(0.8)
    end
  end

  describe "исход и задержка" do
    it "сбой раскладывается на rejected и expired" do
      unlucky = build_provider("unlucky", conversion_24h: 0.0)
      statuses = (1..80).map do |i|
        simulator(seed: 3, expired_share: 0.5).simulate(unlucky, build_operation(operation_id: "op_#{i}")).status
      end

      expect(statuses.uniq).to contain_exactly("rejected", "expired")
    end

    it "expired_share = 0 не порождает просрочек вовсе" do
      unlucky = build_provider("unlucky", conversion_24h: 0.0)
      statuses = (1..40).map do |i|
        simulator(seed: 3, expired_share: 0.0).simulate(unlucky, build_operation(operation_id: "op_#{i}")).status
      end

      expect(statuses.uniq).to eq(["rejected"])
    end

    # У expired в истории средняя задержка 585 секунд против ~55 у остальных.
    # Одна общая выборка дала бы середину, которой не бывает ни у одного исхода.
    it "просрочка длится заметно дольше обычного ответа" do
      unlucky = build_provider("unlucky", conversion_24h: 0.0, avg_latency_sec: 40)
      outcomes = (1..60).map do |i|
        simulator(seed: 5).simulate(unlucky, build_operation(operation_id: "op_#{i}"))
      end

      expired = outcomes.select { |o| o.status == "expired" }.map(&:latency_sec)
      rejected = outcomes.select { |o| o.status == "rejected" }.map(&:latency_sec)

      expect(expired.min).to be > rejected.max
    end

    it "берёт задержку из истории по тому же статусу" do
      rows = Array.new(10) do
        { "payment_system" => "vipay", "status" => "approved", "bank" => "sberbank",
          "amount" => "1000", "card_brand" => "", "latency_sec" => "100" }
      end
      stats = Routing::ConversionStats.new(rows)
      lucky = build_provider("vipay", conversion_24h: 1.0, avg_latency_sec: 10)

      outcome = simulator(stats: stats, seed: 1).simulate(lucky, operation)

      expect(outcome.status).to eq("approved")
      # Медиана истории 100 с плюс разброс ±30%, а не заявленные 10 с.
      expect(outcome.latency_sec).to be_between(70, 130)
    end

    it "исход становится известен через latency после отправки" do
      outcome = simulator(seed: 1).simulate(provider, operation)

      expect(outcome.known_at).to eq(operation.created_at + outcome.latency_sec)
      expect(outcome.latency_sec).to be_positive
    end

    it "без времени у заявки known_at не выдумывается" do
      outcome = simulator(seed: 1).simulate(provider, build_operation)
      expect(outcome.known_at).to be_nil
    end

    it "статус всегда из допустимого словаря" do
      statuses = (1..50).map do |i|
        simulator(seed: i).simulate(provider, build_operation(operation_id: "op_#{i}")).status
      end

      expect(statuses.uniq - described_class::STATUSES).to be_empty
    end
  end
end
