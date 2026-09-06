require "time"
require_relative "errors"
require_relative "provider"

module Routing
  # Заявка из operations_queue.json.
  class Operation
    attr_reader :id, :amount, :bank, :merchant_margin_pct, :created_at, :raw

    def self.from_hash(hash)
      raise InvalidInputError, "заявка задана не объектом: #{hash.inspect}" unless hash.is_a?(Hash)

      id = fetch_any(hash, "operation_id", "id")
      raise InvalidInputError, "у заявки нет operation_id: #{hash.inspect}" if id.to_s.strip.empty?

      new(
        id: id.to_s,
        amount: parse_amount(fetch_any(hash, "amount", "sum"), id),
        bank: fetch_any(hash, "bank", "bank_name", "bank_code"),
        merchant_margin_pct: parse_optional_number(fetch_any(hash, "merchant_margin_pct"), id),
        created_at: parse_time(fetch_any(hash, "created_at", "timestamp", "datetime"), id),
        raw: hash
      )
    end

    def self.fetch_any(hash, *keys)
      keys.each do |key|
        value = hash[key] || hash[key.to_sym]
        return value unless value.nil?
      end
      nil
    end

    def self.parse_amount(value, id)
      raise InvalidInputError, "#{id}: не указана сумма" if value.nil?

      amount = value.is_a?(Numeric) ? value : Float(value)
      raise InvalidInputError, "#{id}: сумма должна быть больше нуля (#{amount})" if amount <= 0

      amount
    rescue ArgumentError, TypeError
      raise InvalidInputError, "#{id}: сумма не число (#{value.inspect})"
    end

    def self.parse_optional_number(value, id)
      return nil if value.nil?
      return value if value.is_a?(Numeric)

      Float(value)
    rescue ArgumentError, TypeError
      raise InvalidInputError, "#{id}: ожидалось число, получено #{value.inspect}"
    end

    def self.parse_time(value, _id)
      return nil if value.nil?
      return value if value.is_a?(Time)

      Time.parse(value.to_s)
    rescue ArgumentError
      nil # некритично: время нужно только для окна RPM, упадём на часы состояния
    end

    def initialize(id:, amount:, bank: nil, merchant_margin_pct: nil, created_at: nil, raw: {})
      @id = id
      @amount = amount
      @bank = bank
      @merchant_margin_pct = merchant_margin_pct
      @created_at = created_at
      @raw = raw
    end

    # Платёжная система карты. Отдельным полем не разбираем: в очереди она везде null,
    # а срез по ней нужен только статистике — но лазить в raw снаружи всё равно не стоит.
    def card_brand
      raw["card_brand"] || raw[:card_brand]
    end

    def normalized_bank
      Provider.normalize_bank(bank)
    end

    def bank?
      !normalized_bank.empty?
    end

    def to_s
      "#{id} (#{amount})"
    end
  end
end
