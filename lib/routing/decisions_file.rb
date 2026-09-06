require "fileutils"
require "json"

module Routing
  # Запись JSON-артефакта на диск. Общее для обоих сдаваемых файлов: создать каталог,
  # записать pretty-JSON с переводом строки в конце.
  module JsonFile
    module_function

    def write(path, payload)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(payload) + "\n")
      path
    end
  end

  # Сериализация решений в формат routing_decisions_test.json из ТЗ.
  #
  # Отдельный файл, потому что это формат сдаваемого артефакта, а не деталь печати:
  # имя, набор ключей и структура attempts[] проверяются автоматическим валидатором
  # организаторов, и менять их можно только осознанно.
  #
  #   [{ "operation_id", "selected_provider", "attempts": [{ "provider", "decision",
  #      "reason", "details" }], "simulated_result", "latency_sec" }]
  module DecisionsFile
    module_function

    def write(path, decisions)
      JsonFile.write(path, payload(decisions))
    end

    def payload(decisions)
      decisions.map { |decision| entry(decision) }
    end

    def entry(decision)
      item = {
        "operation_id" => decision.operation.id,
        # Провайдера нет только у fallback — заявка ушла нам самим.
        "selected_provider" => decision.provider ? decision.provider.name : SELF_PROVIDER,
        "attempts" => decision.attempts.map(&:to_h)
      }

      # Симулятор можно выключить конфигом; тогда этих полей просто нет,
      # а не стоят выдуманные значения.
      if decision.outcome
        item["simulated_result"] = decision.outcome.status
        item["latency_sec"] = decision.outcome.latency_sec
      end

      item
    end
  end
end
