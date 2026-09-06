RSpec.describe Routing::HardConstraints do
  def reason_for(provider, operation, state = build_state(provider))
    attempt = described_class.evaluate(provider, operation, state)
    attempt && attempt.reason
  end

  describe "статус провайдера" do
    it "пропускает active" do
      provider = build_provider(status: "active")
      expect(reason_for(provider, build_operation)).to be_nil
    end

    it "отсекает всё, кроме active" do
      provider = build_provider(status: "disabled")
      expect(reason_for(provider, build_operation)).to eq("provider_inactive")
    end

    it "считает провайдера без поля status активным" do
      expect(reason_for(build_provider, build_operation)).to be_nil
    end
  end

  describe "диапазон суммы чека" do
    let(:provider) { build_provider(limit_amount_min: 1000, limit_amount_max: 100_000) }

    it "отсекает сумму выше максимума" do
      attempt = described_class.evaluate(provider, build_operation(amount: 150_000), build_state(provider))
      expect(attempt.reason).to eq("amount_exceeds_limit")
      expect(attempt.details).to eq("150000 > limit_amount_max 100000")
    end

    it "отсекает сумму ниже минимума" do
      expect(reason_for(provider, build_operation(amount: 500))).to eq("amount_below_minimum")
    end

    it "считает обе границы допустимыми" do
      expect(reason_for(provider, build_operation(amount: 1000))).to be_nil
      expect(reason_for(provider, build_operation(amount: 100_000))).to be_nil
    end
  end

  describe "дневной лимит" do
    it "отсекает, если заявка выводит оборот за лимит" do
      provider = build_provider(daily_amount_limit: 100_000, daily_approved_amount: 95_000)
      expect(reason_for(provider, build_operation(amount: 10_000))).to eq("daily_limit_exceeded")
    end

    it "пропускает заявку, которая ровно добивает лимит" do
      provider = build_provider(daily_amount_limit: 100_000, daily_approved_amount: 95_000)
      expect(reason_for(provider, build_operation(amount: 5_000))).to be_nil
    end

    it "учитывает более строгий daily_turnover_max" do
      provider = build_provider(daily_amount_limit: 1_000_000, daily_turnover_max: 50_000)
      attempt = described_class.evaluate(provider, build_operation(amount: 60_000), build_state(provider))
      expect(attempt.reason).to eq("daily_limit_exceeded")
      expect(attempt.details).to include("daily_turnover_max")
    end

    it "смотрит на оборот из состояния, а не из providers.json" do
      provider = build_provider(daily_amount_limit: 100_000, daily_approved_amount: 0)
      state = build_state(provider)
      state.add_daily_turnover(provider, 95_000)

      expect(reason_for(provider, build_operation(amount: 10_000), state)).to eq("daily_limit_exceeded")
    end
  end

  describe "лимиты in-progress" do
    it "отсекает по количеству" do
      provider = build_provider(in_progress_count_limit: 3, in_progress_count: 3)
      expect(reason_for(provider, build_operation)).to eq("in_progress_count_limit")
    end

    it "отсекает по сумме" do
      provider = build_provider(in_progress_amount_limit: 50_000, in_progress_amount: 45_000)
      expect(reason_for(provider, build_operation(amount: 10_000))).to eq("in_progress_amount_limit")
    end

    it "видит заявки, добавленные в состояние по ходу очереди" do
      provider = build_provider(in_progress_count_limit: 2, in_progress_count: 0)
      state = build_state(provider)
      2.times { state.add_in_progress(provider, 1_000) }

      expect(reason_for(provider, build_operation, state)).to eq("in_progress_count_limit")
    end
  end

  describe "банковский фильтр" do
    it "отсекает банк вне белого списка" do
      provider = build_provider(banks: %w[sber tinkoff])
      expect(reason_for(provider, build_operation(bank: "vtb"))).to eq("bank_not_in_list")
    end

    it "отсекает банк из чёрного списка" do
      provider = build_provider(exclude_banks: %w[vtb])
      expect(reason_for(provider, build_operation(bank: "VTB"))).to eq("bank_excluded")
    end

    # В боевых данных exclude_banks — булев флаг, переключающий смысл banks.
    it "читает banks как чёрный список при exclude_banks: true" do
      provider = build_provider(banks: %w[vtb], exclude_banks: true)

      expect(reason_for(provider, build_operation(bank: "vtb"))).to eq("bank_excluded")
      expect(reason_for(provider, build_operation(bank: "sber"))).to be_nil
    end

    it "читает banks как белый список при exclude_banks: false" do
      provider = build_provider(banks: %w[sberbank tinkoff], exclude_banks: false)

      expect(reason_for(provider, build_operation(bank: "sberbank"))).to be_nil
      expect(reason_for(provider, build_operation(bank: "alfa"))).to eq("bank_not_in_list")
    end

    it "сравнивает названия банков без учёта регистра и пробелов" do
      provider = build_provider(banks: ["Sber"])
      expect(reason_for(provider, build_operation(bank: " sber "))).to be_nil
    end

    it "трактует пустой banks как отсутствие фильтра" do
      provider = build_provider(banks: [])
      expect(reason_for(provider, build_operation(bank: "vtb"))).to be_nil
    end

    it "не допускает заявку без банка к провайдеру с фильтром" do
      provider = build_provider(banks: %w[sber])
      expect(reason_for(provider, build_operation(bank: nil))).to eq("bank_unknown")
    end

    it "пропускает заявку без банка, если провайдер по банкам не фильтрует" do
      expect(reason_for(build_provider, build_operation(bank: nil))).to be_nil
    end
  end

  describe "маржа" do
    it "отсекает провайдера дороже мерчанта" do
      provider = build_provider(provider_margin_pct: 3.0)
      expect(reason_for(provider, build_operation(merchant_margin_pct: 2.5))).to eq("negative_margin")
    end

    it "пропускает при равной марже" do
      provider = build_provider(provider_margin_pct: 2.5)
      expect(reason_for(provider, build_operation(merchant_margin_pct: 2.5))).to be_nil
    end

    it "пропускает при allow_negative_agreement" do
      provider = build_provider(provider_margin_pct: 3.0, allow_negative_agreement: true)
      expect(reason_for(provider, build_operation(merchant_margin_pct: 2.5))).to be_nil
    end

    it "берёт merchant_margin_pct провайдера, если у заявки его нет" do
      provider = build_provider(provider_margin_pct: 3.0, merchant_margin_pct: 2.5)
      expect(reason_for(provider, build_operation)).to eq("negative_margin")
    end

    it "не проверяет маржу, если сравнивать не с чем" do
      provider = build_provider(provider_margin_pct: 3.0)
      expect(reason_for(provider, build_operation)).to be_nil
    end
  end

  describe "реквизиты" do
    it "отсекает при нуле свободных реквизитов" do
      provider = build_provider(available_requisites: 0)
      expect(reason_for(provider, build_operation)).to eq("no_available_requisites")
    end

    it "не считает отсутствие поля нулём" do
      expect(reason_for(build_provider, build_operation)).to be_nil
    end
  end

  describe "интенсивность" do
    let(:provider) { build_provider(requests_per_minute_limit: 2) }
    let(:start) { Time.at(1_700_000_000) }

    it "отсекает при достижении лимита в минуту" do
      state = build_state(provider)
      2.times { state.record_request(provider, at: start) }

      expect(reason_for(provider, build_operation(created_at: start.iso8601), state))
        .to eq("rate_limit_exceeded")
    end

    it "освобождает провайдера, когда окно уехало" do
      state = build_state(provider)
      2.times { state.record_request(provider, at: start) }

      later = build_operation(created_at: (start + 61).iso8601)
      expect(reason_for(provider, later, state)).to be_nil
    end

    it "не ограничивает провайдера без requests_per_minute_limit" do
      plain = build_provider
      state = build_state(plain)
      10.times { state.record_request(plain, at: start) }

      expect(reason_for(plain, build_operation, state)).to be_nil
    end
  end

  describe ".eligible" do
    let(:providers) do
      Routing::DataLoader.providers(File.join(SpecHelpers::FIXTURES, "providers.json")).items
    end
    let(:state) { build_state(providers) }

    it "разделяет пул на допущенных и отклонённых с причинами" do
      result = described_class.eligible(providers, build_operation(amount: 20_000, bank: "sberbank"), state)

      expect(result.eligible.map(&:name)).to eq(%w[vipay payflow spacepayments])
      expect(result.rejections.map { |a| [a.provider, a.reason] }).to eq(
        [["quickpay", "no_available_requisites"], ["oldgate", "provider_inactive"]]
      )
    end

    it "сохраняет исходный порядок провайдеров: ранжирование не его дело" do
      result = described_class.eligible(providers, build_operation(amount: 1_500, bank: "alfa"), state)
      expect(result.eligible.map(&:name)).to eq(%w[vipay payflow spacepayments])
    end

    it "оставляет пустой пул, когда сумма не подходит никому из внешних" do
      result = described_class.eligible(providers[0..3], build_operation(amount: 5_000_000), state)

      expect(result).to be_empty
      expect(result.rejections.map(&:reason)).to include("amount_exceeds_limit")
    end

    it "отдаёт по одной причине на провайдера — первую по порядку проверок из ТЗ" do
      provider = build_provider(status: "disabled", limit_amount_max: 10, available_requisites: 0)
      result = described_class.eligible([provider], build_operation(amount: 99_999), build_state(provider))

      expect(result.rejections.size).to eq(1)
      expect(result.rejections.first.reason).to eq("provider_inactive")
    end

    it "не падает на провайдере, у которого заполнено только имя" do
      bare = build_provider("newgate")
      result = described_class.eligible([bare], build_operation, build_state(bare))

      expect(result.eligible.map(&:name)).to eq(["newgate"])
    end

    it "отдаёт attempts в формате routing_decisions" do
      result = described_class.eligible(providers, build_operation(amount: 20_000, bank: "sberbank"), state)

      expect(result.rejections.first.to_h).to eq(
        "provider" => "quickpay",
        "decision" => "skipped",
        "reason" => "no_available_requisites",
        "details" => "available_requisites 0"
      )
    end
  end

  describe "набор проверок" do
    it "можно сузить, не трогая остальную логику" do
      filter = Routing::HardConstraints::Filter.new(checks: [Routing::HardConstraints::StatusCheck])
      provider = build_provider(status: "active", limit_amount_max: 10)

      expect(filter.eligible?(provider, build_operation(amount: 99_999), build_state(provider))).to be true
    end
  end
end

RSpec.describe "разбор входных данных" do
  it "сообщает про заявку без суммы" do
    expect { Routing::Operation.from_hash("operation_id" => "op_1") }
      .to raise_error(Routing::InvalidInputError, /не указана сумма/)
  end

  it "сообщает про отрицательную сумму" do
    expect { Routing::Operation.from_hash("operation_id" => "op_1", "amount" => -5) }
      .to raise_error(Routing::InvalidInputError, /больше нуля/)
  end

  it "сообщает про перевёрнутый диапазон лимитов провайдера" do
    expect { Routing::Provider.from_hash("name" => "x", "limit_amount_min" => 100, "limit_amount_max" => 10) }
      .to raise_error(Routing::InvalidInputError, /limit_amount_min/)
  end

  it "не роняет прогон из-за одной битой заявки" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "queue.json")
      File.write(path, JSON.dump([
        { "operation_id" => "op_1", "amount" => 1000 },
        { "operation_id" => "op_2" },
        { "operation_id" => "op_3", "amount" => 2000 }
      ]))

      loaded = Routing::DataLoader.operations(path)
      expect(loaded.items.map(&:id)).to eq(%w[op_1 op_3])
      expect(loaded.errors.size).to eq(1)
    end
  end
end
