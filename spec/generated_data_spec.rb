require "tmpdir"
require "stringio"

require_relative "../bin/hard_filter_run"

# Синтетические данные полезны, только если задевают каждую проверку. Если генератор
# подкрутили и часть фильтров перестала срабатывать — прогон превращается в самообман,
# и об этом должен сказать упавший тест, а не молчаливо зелёная сводка.
RSpec.describe "прогон hard-фильтров на data/" do
  DATA_DIR = File.expand_path("../data", __dir__)

  # Все причины, которые умеют выдавать проверки из реестра.
  ALL_REASONS = %w[
    provider_inactive
    amount_below_limit
    amount_exceeds_limit
    daily_limit_exceeded
    in_progress_count_limit
    in_progress_amount_limit
    bank_not_in_list
    bank_excluded
    bank_unknown
    negative_margin
    no_available_requisites
    rate_limit_exceeded
  ].freeze

  let(:decisions) do
    Dir.mktmpdir do |dir|
      silence_output do
        HardFilterRun.run(
          queue_path: File.join(DATA_DIR, "operations_queue_test.json"),
          providers_path: File.join(DATA_DIR, "providers.json"),
          out_path: File.join(dir, "decisions.json")
        )
      end
    end
  end

  let(:attempts) { decisions.flat_map(&:attempts) }

  def silence_output
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  it "данные читаются без ошибок разбора" do
    providers = Routing::DataLoader.providers(File.join(DATA_DIR, "providers.json"))
    queue = Routing::DataLoader.operations(File.join(DATA_DIR, "operations_queue_test.json"))

    expect(providers.errors).to be_empty
    expect(queue.errors).to be_empty
    expect(queue.items.size).to be >= 100
  end

  it "решение принято по каждой заявке" do
    expect(decisions.size).to eq(
      Routing::DataLoader.operations(File.join(DATA_DIR, "operations_queue_test.json")).items.size
    )
  end

  it "задевает каждую hard-проверку хотя бы раз" do
    observed = attempts.select(&:skipped?).map(&:reason).uniq
    expect(ALL_REASONS - observed).to be_empty
  end

  it "у каждой заявки ровно один selected" do
    decisions.each do |decision|
      selected = decision.attempts.reject(&:skipped?)
      expect(selected.size).to eq(1), "#{decision.operation.id}: selected #{selected.size}"
    end
  end

  it "не выбирает неактивного провайдера" do
    chosen = decisions.map { |d| d.provider && d.provider.name }.compact.uniq
    expect(chosen).not_to include("oldgate")
  end

  it "уходит в fallback, когда пул пустеет" do
    expect(decisions.count(&:fallback)).to be > 0
  end

  it "копит оборот по ходу очереди, а не читает его из providers.json" do
    # vipay стартует с 3 215 000 при лимите 5 000 000 — к концу очереди он должен
    # заметно продвинуться и упереться в дневной лимит.
    reasons = attempts.select(&:skipped?)
    vipay_daily = reasons.count { |a| a.provider == "vipay" && a.reason == "daily_limit_exceeded" }
    expect(vipay_daily).to be > 0
  end

  it "не отдаёт заявку провайдеру, у которого сумма вне диапазона" do
    limits = Routing::DataLoader.providers(File.join(DATA_DIR, "providers.json"))
                                .items.to_h { |p| [p.name, p] }

    decisions.reject(&:fallback).each do |decision|
      provider = limits.fetch(decision.provider.name)
      amount = decision.operation.amount
      expect(amount).to be_between(provider.limit_amount_min, provider.limit_amount_max),
                        "#{decision.operation.id}: #{amount} вне #{provider.name}"
    end
  end
end
