require "json"
require_relative "errors"
require_relative "operation"
require_relative "provider"

module Routing
  # Чтение providers.json / operations_queue.json.
  # Битая запись не должна ронять весь прогон: она попадает в errors, остальные обрабатываются.
  module DataLoader
    module_function

    Loaded = Struct.new(:items, :errors, keyword_init: true)

    def providers(path)
      load_list(path, "providers") { |hash| Provider.from_hash(hash) }
    end

    def operations(path)
      load_list(path, "operations") { |hash| Operation.from_hash(hash) }
    end

    def load_list(path, key)
      raise InvalidInputError, "файл не найден: #{path}" unless File.exist?(path)

      raw = parse_json(path)
      rows = raw.is_a?(Hash) ? (raw[key] || raw.values.find { |v| v.is_a?(Array) }) : raw
      raise InvalidInputError, "#{path}: ожидался массив записей" unless rows.is_a?(Array)

      items = []
      errors = []
      rows.each_with_index do |row, index|
        begin
          items << yield(row)
        rescue InvalidInputError => e
          errors << "запись ##{index}: #{e.message}"
        end
      end

      Loaded.new(items: items, errors: errors)
    end

    def parse_json(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise InvalidInputError, "#{path}: не разобрать JSON (#{e.message})"
    end
  end
end
