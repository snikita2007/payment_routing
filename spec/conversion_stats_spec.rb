require "tmpdir"

RSpec.describe Routing::ConversionStats do
  def row(provider:, status:, bank: "sberbank", amount: "10000", card: "", latency: "40")
    {
      "payment_system" => provider, "status" => status, "bank" => bank,
      "amount" => amount, "card_brand" => card, "latency_sec" => latency
    }
  end

  describe "сглаживание" do
    # Сырая доля на маленькой выборке — это шум: три заявки подряд дают ровно 100%,
    # и без подтягивания к родителю скорер начнёт верить трём строкам как сорока.
    it "подтягивает редкую клетку к родительской ставке" do
      rows = Array.new(3) { row(provider: "payflow", status: "approved") } +
             Array.new(17) { row(provider: "vipay", status: "rejected") }
      stats = described_class.new(rows, prior_strength: 5)

      raw = 1.0
      smoothed = stats.overall_rate("payflow")

      expect(smoothed).to be < raw
      expect(smoothed).to be > stats.global_rate
    end

    it "чем больше выборка, тем ближе к сырой доле" do
      few = described_class.new(Array.new(4) { row(provider: "a", status: "approved") } +
                                Array.new(4) { row(provider: "b", status: "rejected") })
      many = described_class.new(Array.new(200) { row(provider: "a", status: "approved") } +
                                 Array.new(200) { row(provider: "b", status: "rejected") })

      expect(many.overall_rate("a")).to be > few.overall_rate("a")
      expect(many.overall_rate("a")).to be_within(0.02).of(1.0)
    end

    it "не принимает нулевую силу сглаживания — на ней пустая клетка даёт 0/0" do
      expect { described_class.new([], prior_strength: 0) }
        .to raise_error(Routing::InvalidInputError, /prior_strength/)
    end
  end

  describe "срезы" do
    let(:rows) do
      Array.new(10) { row(provider: "vipay", bank: "sberbank", status: "approved") } +
        Array.new(10) { row(provider: "vipay", bank: "alfa", status: "rejected") } +
        Array.new(10) { row(provider: "quickpay", bank: "sberbank", status: "rejected") }
    end

    it "учитывает банк заявки, а не только общую ставку провайдера" do
      stats = described_class.new(rows)

      good = stats.estimate("vipay", bank: "sberbank", amount: 10_000).value
      bad = stats.estimate("vipay", bank: "alfa", amount: 10_000).value

      expect(good).to be > bad
    end

    # Колонка card_brand пуста во всех 100 строках боевой истории, а в очереди card_brand
    # везде null. Без перенормировки 0.10 веса просто исчезали бы из формулы.
    it "выбрасывает срез без данных и перенормирует веса оставшихся" do
      stats = described_class.new(rows)
      estimate = stats.estimate("vipay", bank: "sberbank", amount: 10_000, card_brand: nil)

      expect(estimate.slices.map(&:key)).not_to include("card")
      expect(estimate.slices.sum(&:weight)).to be_within(1e-9).of(1.0)
    end

    it "тонкую клетку взвешивает меньше, чем толстую" do
      thin = described_class.new(
        Array.new(30) { row(provider: "vipay", bank: "sberbank", status: "approved") } +
        [row(provider: "vipay", bank: "vtb", status: "approved")]
      )
      estimate = thin.estimate("vipay", bank: "vtb", amount: 10_000)

      bank_slice = estimate.slices.find { |slice| slice.key == "bank" }
      overall_slice = estimate.slices.find { |slice| slice.key == "overall" }

      expect(bank_slice.n).to eq(1)
      expect(bank_slice.weight).to be < overall_slice.weight
    end

    it "незнакомому провайдеру отдаёт глобальную ставку и говорит об этом" do
      stats = described_class.new(rows)
      estimate = stats.estimate("newcomer", bank: "sberbank", amount: 10_000)

      expect(estimate.value).to be_within(1e-9).of(stats.global_rate)
      expect(estimate.source).to include("нет данных")
    end
  end

  describe "отсутствие истории" do
    it "не падает и отдаёт нейтральную середину" do
      stats = described_class.load(File.join(Dir.tmpdir, "нет-такого-файла.csv"))

      expect(stats).to be_empty
      expect(stats.estimate("vipay", bank: "sberbank", amount: 1000).value).to eq(0.5)
    end
  end

  describe "боевая история" do
    let(:stats) { described_class.load(File.expand_path("../data/operations_history.csv", __dir__)) }

    it "читается без ошибок разбора" do
      expect(stats.errors).to be_empty
      expect(stats).not_to be_empty
      expect(stats.providers).to include("vipay", "payflow", "quickpay")
    end

    # Главное расхождение данных: providers.json объявляет payflow лучшим по конверсии,
    # история — худшим. От выбора источника ранжирование разворачивается.
    it "показывает у payflow конверсию заметно ниже заявленных 0.91" do
      expect(stats.overall_rate("payflow")).to be < 0.6
      expect(stats.overall_rate("vipay")).to be > stats.overall_rate("payflow")
    end

    it "медиану времени считает по успешным заявкам, не по просроченным" do
      expect(stats.median_latency("payflow")).to be < 200
    end
  end

  describe "разбор файла" do
    it "переживает мусорную строку, не теряя остальные" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "history.csv")
        File.write(path, <<~CSV)
          operation_id,created_at,amount,bank,card_brand,payment_system,status,latency_sec
          op_1,2026-07-29T08:00:00+03:00,12000,alfa,,vipay,approved,76
          сломанная,строка
          op_2,2026-07-29T08:01:00+03:00,5000,vtb,,vipay,rejected,6
        CSV

        stats = described_class.load(path)
        expect(stats.sample_size("vipay")).to eq(2)
      end
    end
  end
end
