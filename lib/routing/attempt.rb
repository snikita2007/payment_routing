module Routing
  # Одна запись из attempts[] в routing_decisions_test.json.
  # Строится в момент решения, а не восстанавливается по логам после.
  class Attempt
    SELECTED = "selected".freeze
    SKIPPED = "skipped".freeze

    attr_reader :provider, :decision, :reason, :details

    def self.skipped(provider, reason, details = nil)
      new(provider: provider, decision: SKIPPED, reason: reason, details: details)
    end

    def self.selected(provider, reason, details = nil)
      new(provider: provider, decision: SELECTED, reason: reason, details: details)
    end

    def initialize(provider:, decision:, reason:, details: nil)
      @provider = provider.to_s
      @decision = decision
      @reason = reason
      @details = details
    end

    def skipped?
      decision == SKIPPED
    end

    def to_h
      hash = { "provider" => provider, "decision" => decision, "reason" => reason }
      hash["details"] = details unless details.nil?
      hash
    end
  end
end
