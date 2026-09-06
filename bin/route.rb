#!/usr/bin/env ruby
# Прогон очереди через полный конвейер: hard-фильтры → soft-скоринг → решение.
#
#   ruby bin/route.rb
#   ruby bin/route.rb --profile declared --out out/run_declared.json
#   ruby bin/route.rb --profile priority_only        # только каскад по priority
#   ruby scripts/validate_10.rb out/routing_decisions.json
#
# Веса и параметры скоринга — в config/scoring.yml, поля, которых нет в providers.json, —
# в config/provider_overrides.yml.
#
# Здесь только разбор аргументов: конвейер собирает Routing::Pipeline, запись решений —
# Routing::DecisionsFile, печать сводки — Routing::ConsoleReport.

require "optparse"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "routing"
require "routing/console_report"
require "routing/decisions_file"
require "routing/pipeline"

ROOT = File.expand_path("..", __dir__)

options = {
  queue: File.join(ROOT, "data", "operations_queue_10.json"),
  providers: File.join(ROOT, "data", "providers.json"),
  out: File.join(ROOT, "out", "routing_decisions.json"),
  report: File.join(ROOT, "out", "routing_report.json"),
  config: nil,
  profile: nil,
  history: nil,
  overrides: nil,
  quiet: false
}

OptionParser.new do |parser|
  parser.banner = "Использование: ruby bin/route.rb [опции]"
  parser.on("--queue PATH", "очередь заявок") { |v| options[:queue] = v }
  parser.on("--providers PATH", "провайдеры") { |v| options[:providers] = v }
  parser.on("--config PATH", "настройки скоринга") { |v| options[:config] = v }
  parser.on("--profile NAME", "профиль весов из конфига") { |v| options[:profile] = v }
  parser.on("--history PATH", "история операций") { |v| options[:history] = v }
  parser.on("--overrides PATH", "оверлей полей провайдеров") { |v| options[:overrides] = v }
  parser.on("--out PATH", "куда положить решения") { |v| options[:out] = v }
  parser.on("--report PATH", "куда положить аналитику") { |v| options[:report] = v }
  parser.on("--quiet", "без сводки, только записать файлы") { options[:quiet] = true }
  parser.on("-h", "--help", "эта справка") { puts parser; exit }
end.parse!

begin
  result = Routing::Pipeline.run(
    queue_path: options[:queue],
    providers_path: options[:providers],
    config_path: options[:config],
    profile: options[:profile],
    history_path: options[:history],
    overrides_path: options[:overrides]
  )

  # Замечания конвейера идут в stderr, чтобы не мешать, когда вывод перенаправляют в файл.
  result.notices.each { |message| warn("  #{message}") }

  Routing::DecisionsFile.write(options[:out], result.decisions)
  Routing::ReportBuilder.write(options[:report], result)
  Routing::ConsoleReport.new(result).print unless options[:quiet]

  puts "\nРешения:  #{options[:out]}"
  puts "Аналитика: #{options[:report]}"
rescue Routing::InvalidInputError => e
  abort "Входные данные негодны: #{e.message}"
end
