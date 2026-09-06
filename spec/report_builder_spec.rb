require "json"

require_relative "spec_helper"

# Отчёт — сдаваемый артефакт, и проверяем его в двух плоскостях: обязательные поля из ТЗ
# на месте, а выводы и рекомендации не врут о причинах.
RSpec.describe Routing::ReportBuilder do
  DATA = File.expand_path("../data", __dir__)

  let(:result) do
    Routing::Pipeline.run(queue_path: File.join(DATA, "operations_queue_10.json"),
                          providers_path: File.join(DATA, "providers.json"))
  end
  let(:report) { described_class.new(result).to_h }

  describe "структура из ТЗ" do
    it "содержит все обязательные поля" do
      expect(report.keys).to include("period", "total_operations", "distribution",
                                     "skip_reasons", "projected_daily_utilization",
                                     "recommendations")
    end

    it "переживает JSON-сериализацию без потерь" do
      expect(JSON.parse(JSON.generate(report))).to eq(report)
    end

    it "берёт период из заявок, а не из системных часов" do
      expect(report["period"]).to eq("2026-07-30")
    end

    it "считает столько операций, сколько было в очереди" do
      expect(report["total_operations"]).to eq(10)
    end
  end

  describe "распределение" do
    it "показывает факт, цель и отклонение по каждому провайдеру" do
      payflow = report["distribution"].fetch("payflow")

      expect(payflow).to include("count", "share_pct", "target_pct", "deviation_pp")
      expect(payflow["deviation_pp"]).to eq(payflow["share_pct"] - payflow["target_pct"])
    end

    it "доли внешних провайдеров дают в сумме 100" do
      total = report["distribution"].values.sum { |row| row["share_pct"] }

      expect(total).to be_within(0.1).of(100.0)
    end

    it "сходится с routing_decisions по количеству" do
      routed = report["distribution"].values.sum { |row| row["count"] }

      expect(routed + report["fallback"]["count"]).to eq(report["total_operations"])
    end
  end

  describe "успешность и лимиты" do
    it "разносит исходы по провайдерам" do
      expect(report["outcomes"]["total"]["total"]).to eq(10)
      expect(report["outcomes"]["by_provider"].keys).to include("vipay", "payflow", "quickpay")
    end

    it "показывает использование дневного лимита" do
      payflow = report["projected_daily_utilization"].fetch("payflow")

      expect(payflow["used"]).to be > 0
      expect(payflow["utilization_pct"]).to be_within(0.1).of(payflow["used"] * 100.0 / payflow["limit"])
    end

    it "не выдумывает процент там, где лимита нет" do
      expect(report["projected_daily_utilization"].fetch("spacepayments")["utilization_pct"]).to be_nil
    end

    # lower_score — исход ранжирования среди допущенных, а не отказ по ограничению.
    # В одной таблице с «сумма вне лимита» он ломал бы саму метрику отсева.
    it "не мешает проигрыш по скору с hard-отказами" do
      expect(report["skip_reasons"].keys).not_to include("lower_score")
      expect(report["outscored_by_score"]).to be > 0
    end
  end

  describe "выводы" do
    it "объясняет недобор конкретным hard-фильтром" do
      note = report["findings"].find { |text| text.start_with?("payflow недобрал") }

      expect(note).to include("bank_not_in_list")
    end

    # Провайдер, взявший сверх цели, «не допускался фильтром» по определению не мог:
    # перебор объясняется отсутствием конкурентов, а не отказом.
    it "объясняет перебор отсутствием конкуренции, а не отказом" do
      note = report["findings"].find { |text| text.start_with?("quickpay перебрал") }

      expect(note).to include("единственным допущенным")
      expect(note).not_to include("не допускал hard-фильтр")
    end

    it "замечает провайдера у потолка дневного лимита" do
      expect(report["findings"]).to include(a_string_matching(/payflow выбрал 9\d\.\d% дневного лимита/))
    end
  end

  describe "рекомендации" do
    it "называют конкретный параметр, а не общие слова" do
      expect(report["recommendations"]).not_to be_empty
      expect(report["recommendations"]).to all(
        a_string_matching(/traffic_percentage|daily_turnover_min|daily_amount_limit|banks|limit_amount_max|traffic_share/)
      )
    end

    it "предлагают снизить долю провайдера у дневного лимита" do
      advice = report["recommendations"].find { |text| text.include?("близок к дневному лимиту") }

      expect(advice).to include("снизить traffic_percentage payflow с 35.0 до 20")
    end

    # Провайдеру, который перебрал долю, нельзя советовать «снизить traffic_percentage
    # до 40» при цели 25 — это не снижение. Перебор без конкуренции лечится пулом.
    it "не советуют перебравшему снижать цель до значения выше самой цели" do
      advice = report["recommendations"].find { |text| text.start_with?("quickpay") }

      expect(advice).to include("расширять пул")
      expect(advice).not_to include("недостижима")
    end
  end

  describe "склонение числительных" do
    it "согласует слово с числом" do
      builder = described_class.new(result)

      expect(builder.send(:plural, 1, "заявка", "заявки", "заявок")).to eq("1 заявка")
      expect(builder.send(:plural, 3, "заявка", "заявки", "заявок")).to eq("3 заявки")
      expect(builder.send(:plural, 5, "заявка", "заявки", "заявок")).to eq("5 заявок")
      expect(builder.send(:plural, 11, "заявка", "заявки", "заявок")).to eq("11 заявок")
      expect(builder.send(:plural, 21, "заявка", "заявки", "заявок")).to eq("21 заявка")
    end
  end
end
