# Маршрутизация платёжных заявок

Решение распределяет заявки из очереди между платёжными провайдерами: сначала отсекает тех,
кому заявку отдать нельзя (hard-constraints), затем ранжирует оставшихся взвешенным скорингом
по нескольким целям сразу (soft-goals) и фиксирует, почему выбран именно этот провайдер и почему
отложены остальные.

Вход — `data/providers.json` (кто может принимать платежи и на каких условиях),
очередь заявок (`data/operations_queue_10.json` — учебная на 10 заявок) и
`data/operations_history.csv` (история для оценки конверсии).
Язык — Ruby, без внешних зависимостей кроме RSpec.

## Сдаваемые файлы

В корне репозитория лежат два артефакта, оба собираются одной командой:

```sh
ruby bin/route.rb --queue data/operations_queue_test.json \
                  --out routing_decisions_test.json \
                  --report routing_report_test.json
```

> **Сейчас оба файла собраны на учебной очереди `data/operations_queue_10.json`** — настоящий
> `operations_queue_test.json` организаторы выдают на хакатоне. Когда он появится, положите его
> в `data/` и выполните команду выше: имена и расположение файлов менять не нужно.

**[routing_decisions_test.json](routing_decisions_test.json)** — решение по каждой заявке.
`attempts[]` содержит и выбранного провайдера, и всех рассмотренных с причиной отсева,
поэтому по файлу видно не только «кого выбрали», но и «почему не остальных»:

```jsonc
{
  "operation_id": "op_101",
  "selected_provider": "vipay",
  "attempts": [
    { "provider": "vipay",    "decision": "selected", "reason": "highest_weighted_score",
      "details": "score 0.476 = conversion 0.27×0.78 + priority 0.08×1.00 + ..." },
    { "provider": "quickpay", "decision": "skipped",  "reason": "lower_score",
      "details": "score 0.398 ... — ниже, чем у vipay (0.476)" }
  ],
  "simulated_result": "approved",   // approved / rejected / expired
  "latency_sec": 51
}
```

**[routing_report_test.json](routing_report_test.json)** — аналитика по этим решениям:

```jsonc
{
  "period": "2026-07-30",
  "total_operations": 10,
  "distribution": {                  // факт против цели, по количеству и по объёму
    "payflow": { "count": 2, "share_pct": 20.0, "target_pct": 35.0, "deviation_pp": -15.0, ... }
  },
  "outcomes": { ... },               // успешность и отказы, всего и по провайдерам
  "skip_reasons": { "bank_not_in_list": 8, ... },
  "projected_daily_utilization": {   // использование дневных лимитов
    "payflow": { "used": 2940800, "limit": 3000000, "utilization_pct": 98.0 }
  },
  "findings": [                      // причины отклонений, с числами
    "payflow недобрал 15.0 п.п. ...; чаще всего его не допускал hard-фильтр bank_not_in_list"
  ],
  "recommendations": [               // конкретный параметр к изменению, а не общие слова
    "payflow близок к дневному лимиту (98.0%) — снизить traffic_percentage payflow с 35.0 до 20."
  ]
}
```

## Запуск

```sh
bundle install

# основной прогон: решения + аналитика в out/ и сводка в консоль
ruby bin/route.rb

# другой профиль весов (см. config/scoring.yml)
ruby bin/route.rb --profile declared
ruby bin/route.rb --profile priority_only     # только каскад по priority

# автопроверка формата ответа
ruby scripts/validate_10.rb out/routing_decisions.json

# тесты
bundle exec rspec
bundle exec rspec spec/hard_constraints_spec.rb:42   # один тест
```

`ruby bin/route.rb --help` перечисляет все флаги. Конфигов может не быть вовсе: дефолты
продублированы в коде (`ScoringConfig::DEFAULTS`), и прогон на непропатченном `providers.json`
не падает.

### Что печатает прогон

```
Профиль: hybrid   traffic_share 0.18  volume_share 0.13  conversion 0.27  ...
Заявок обработано: 10

Распределение против целевого:
  провайдер         шт    факт%    цель%        Δ     объём%    цель%        Δ
  vipay              4    40.0%    40.0%    +0.0      26.4%    35.0%    -8.6
  payflow            2    20.0%    35.0%   -15.0      10.6%    20.0%    -9.4
  quickpay           4    40.0%    25.0%   +15.0      63.0%    45.0%   +18.0

  скорер выбирал: 6, предопределено фильтрами: 4, fallback: 0

Симулированные исходы:
  approved     8   80.0%   средняя задержка 56 с
  ...
Причины отсева:
  bank_not_in_list           8
  lower_score                7
```

Строка «скорер выбирал / предопределено фильтрами» существует не для красоты: без неё
распределение читается как заслуга скоринга, хотя часть заявок выбора не имела вовсе.

## Конвейер

Одна заявка проходит строго такой путь, и порядок значим:

```
operation
  → HardConstraints.eligible   кто вообще может взять эту заявку
  → SoftScorer.rank            ранжирование допущенных взвешенным скором
  → Attempt[]                  причина выбора и причины отсева, тут же
  → RoutingState               обороты, in-progress, счётчики интенсивности
  → ResultSimulator            simulated_result и latency_sec
```

Инварианты, на которых всё держится:

- **Hard и soft не смешиваются.** Hard-ограничение нельзя перевесить весом или скором:
  в скорер попадает только то, что уже прошло фильтры.
- **Состояние меняется после каждой заявки.** Очередь идёт последовательно — следующая заявка
  видит уже сдвинутые обороты и лимиты. Параллелить нельзя.
- **Fallback.** Пустой пул → заявка уходит self-провайдеру `spacepayments`. Фильтры при этом
  не ослабляются: мы не подбираем «почти подходящего».
- **Объяснимость строится в момент решения**, а не восстанавливается по логам потом.
  Фактор возвращает число вместе с текстом, откуда оно взялось.

## Карта файлов

```
bin/route.rb                  CLI: разбор аргументов и всё
lib/routing.rb                точка входа, порядок require повторяет конвейер
lib/routing/
  pipeline.rb                 сборка конвейера и один прогон очереди
  decisions_file.rb           сериализация в формат routing_decisions_test.json
  report_builder.rb           аналитика и рекомендации → routing_report_test.json
  console_report.rb           сводка прогона в консоль
  hard_constraints.rb         все 9 проверок допуска, их порядок и Filter
  factors.rb                  реестр soft-факторов (REGISTERED)
  factors/                    один фактор — один файл
    base_factor.rb  share_factor.rb  traffic_share.rb  volume_share.rb
    conversion.rb  priority.rb  turnover_min.rb  load.rb
    speed.rb  recent_failure.rb
  soft_scorer.rb              взвешенная сумма факторов и разрешение ничьих
  router.rb                   конвейер на одну заявку, attempts[], fallback
  routing_state.rb            изменяемое состояние по ходу очереди
  scoring_config.rb           веса и параметры, профили, дефолты
  conversion_stats.rb         конверсия по истории, срезами и со сглаживанием
  result_simulator.rb         симуляция исхода заявки
  provider.rb  operation.rb  attempt.rb  data_loader.rb
  provider_overrides.rb       поля, которых нет в providers.json
  format.rb  errors.rb
config/scoring.yml            веса и параметры скоринга
config/provider_overrides.yml поля, которые команда задаёт сама
scripts/validate_10.rb        автопроверка формата ответа
```

Куда смотреть, чтобы понять решение: [lib/routing/router.rb](lib/routing/router.rb) — весь путь
одной заявки на 130 строках; [config/scoring.yml](config/scoring.yml) — что и с каким весом
влияет на выбор.

## Скоринг

```
Score = w_t·D_t + w_v·D_v + w_c·C + w_p·P + w_m·M + w_l·L + w_s·Speed − w_f·RecentFailure
```

| Ключ | Фактор | Что меряет |
|---|---|---|
| `traffic_share` | D_t | недобор целевой доли по количеству заявок (`traffic_percentage`) |
| `volume_share` | D_v | недобор целевой доли по объёму денег (`volume_share_pct`) |
| `conversion` | C | вероятность одобрения: по истории, заявленная или смесь |
| `priority` | P | позиция в каскаде, `1 / priority` |
| `turnover_min` | M | недобор обещанного дневного оборота (`daily_turnover_min`) |
| `load` | L | свободная мощность: `1 −` загрузка in-progress |
| `speed` | Speed | скорость ответа относительно `latency_scale_sec` |
| `recent_failure` | — | штраф за свежие сбои с экспоненциальным затуханием |

Веса и все параметры — в [config/scoring.yml](config/scoring.yml), с объяснением каждого числа.
Профиль — именованный набор весов: `hybrid` (основной), `declared` (без истории),
`priority_only` (чистый каскад). Фактор с нулевым весом не считается вовсе.

Ничьи разрешает цепочка `tie_break` из конфига, последним звеном — исходный порядок пула,
поэтому прогон полностью детерминирован.

Диапазон суммы и загрузка работают **и** как hard-ограничение, **и** как soft-фактор: первое
отвечает «влезет или нет», второе — «насколько провайдер уже занят».

## Как добавить правило

**Новый soft-фактор** — код трогать не придётся нигде, кроме самого фактора:

1. Класс в `lib/routing/factors/`, наследник `BaseFactor`, с константой `KEY` и методом
   `#assess(provider, operation, state)`, возвращающим `result(значение, "объяснение")`.
2. Строка в `REGISTERED` в [lib/routing/factors.rb](lib/routing/factors.rb).
3. Вес в `config/scoring.yml`.

**Новый hard-фильтр**: класс в [lib/routing/hard_constraints.rb](lib/routing/hard_constraints.rb)
с методом `#call`, который отдаёт `skip(provider, reason, details)` при отказе и `nil` при проходе,
плюс строка в `DEFAULT_CHECKS` там же. Порядок в списке решает, какая причина попадёт в `attempts`,
если провайдер нарушает сразу несколько условий.

Проверки лежат одним файлом намеренно: каждая — полтора десятка строк, и все они делят общий
словарь причин (`amount_exceeds_limit`, `bank_not_in_list`, …), который обязан совпадать с эталоном
организаторов. Целиком этот набор виден только так. Факторы разнесены по файлам как раз потому,
что там наоборот: каждый несёт свою формулу и её обоснование на 30–90 строк.

Ни `SoftScorer`, ни `Router`, ни `Filter` при этом не меняются.

## Поля, которых нет в исходных данных

Полей `volume_share_pct`, `priority`, `requests_per_minute_limit`, `daily_turnover_min`
и `daily_turnover_max` в исходном `providers.json` нет — их задаёт команда. Они живут в
[config/provider_overrides.yml](config/provider_overrides.yml), а не в `data/providers.json`:
на сдаче организаторы пришлют свой `providers.json`, и правки в файле данных пропали бы вместе
с ним. Все поля читаются через дефолты, так что решение работает и без оверлея.

Прогон говорит вслух, что именно дозаполнил своими значениями, — в отчёте видно, где цифра
из данных, а где наша.

## Известные ограничения

- Фактор `recent_failure` просматривает журнал исходов целиком на каждой оценке, поэтому время
  прогона растёт квадратично от длины очереди. На реальных объёмах это незаметно (1000 заявок —
  около 0.25 с), на 4000 заявок — порядка 1.7 с. Чинится либо окном по журналу, либо
  инкрементальным пересчётом затухания; и то и другое усложняет самый тонкий фактор, поэтому
  оставлено как есть.
- `card_brand` пуст во всех строках истории и во всей очереди, поэтому одноимённый срез конверсии
  всегда выпадает, а его вес перераспределяется между остальными срезами.
