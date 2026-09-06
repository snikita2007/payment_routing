require "tmpdir"

RSpec.describe Routing::ScoringConfig do
  def with_config(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "scoring.yml")
      File.write(path, yaml)
      yield path
    end
  end

  it "работает без файла вовсе — на одних дефолтах" do
    config = described_class.load(nil)

    expect(config.profile_name).to eq("hybrid")
    expect(config.weight("conversion")).to eq(0.264)
  end

  # Ради этого дефолты и продублированы в коде: на сдаче достаточно поправить одну строку,
  # не переписывая весь файл и не рискуя потерять остальные параметры.
  it "принимает частичный файл, дополняя его дефолтами" do
    with_config("profiles:\n  hybrid:\n    weights:\n      conversion: 0.5\n") do |path|
      config = described_class.load(path)

      expect(config.weight("conversion")).to eq(0.5)
      expect(config.weight("traffic_share")).to eq(0.176)
      expect(config.options("speed")["latency_scale_sec"]).to eq(120)
    end
  end

  it "переключает профиль, не трогая код" do
    config = described_class.load(nil, profile: "declared")

    expect(config.weight("speed")).to eq(0.0)
    expect(config.options("conversion")["source"]).to eq("declared")
  end

  it "профиль переопределяет секцию верхнего уровня" do
    default = described_class.load(nil)
    declared = default.with_profile("declared")

    expect(default.options("conversion")["source"]).to eq("history")
    expect(declared.options("conversion")["source"]).to eq("declared")
    # Остальные параметры секции при этом на месте.
    expect(declared.options("conversion")["prior_strength"]).to eq(5)
  end

  it "на неизвестный профиль отвечает списком существующих" do
    expect { described_class.load(nil, profile: "нетакого") }
      .to raise_error(Routing::InvalidInputError, /неизвестный профиль.*hybrid/m)
  end

  describe "проверка весов" do
    it "ловит опечатку в имени фактора" do
      with_config("profiles:\n  hybrid:\n    weights:\n      converssion: 0.3\n") do |path|
        expect { described_class.load(path).validate_weights!(Routing::Factors.keys) }
          .to raise_error(Routing::InvalidInputError, /неизвестные факторы.*converssion/)
      end
    end

    it "не даёт свести выбор к одному tie_break нулевыми весами" do
      yaml = "profiles:\n  hybrid:\n    weights:\n      " \
             "traffic_share: 0\n      volume_share: 0\n      conversion: 0\n      " \
             "priority: 0\n      turnover_min: 0\n      load: 0\n      speed: 0\n      " \
             "recent_failure: 0\n"

      with_config(yaml) do |path|
        expect { described_class.load(path).validate_weights!(Routing::Factors.keys) }
          .to raise_error(Routing::InvalidInputError, /все веса нулевые/)
      end
    end

    it "у поставляемых профилей веса дают ровно единицу" do
      %w[hybrid declared priority_only].each do |name|
        expect(described_class.load(nil, profile: name).weights_sum_warning).to be_nil, name
      end
    end

    # Сумма не единица — не ошибка, но читать конфиг после этого нельзя:
    # «0.30 у конверсии» перестаёт означать 30% решения.
    it "предупреждает, когда веса не дают единицу" do
      with_config("profiles:\n  hybrid:\n    weights:\n      conversion: 0.9\n") do |path|
        expect(described_class.load(path).weights_sum_warning).to match(/в сумме/)
      end
    end
  end

  it "отвергает неизвестное правило tie_break" do
    with_config("tie_break: [пойдёт_как_нибудь]\n") do |path|
      expect { Routing::SoftScorer.new(config: described_class.load(path)) }
        .to raise_error(Routing::InvalidInputError, /tie_break/)
    end
  end
end
