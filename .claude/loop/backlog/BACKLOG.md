# Бэклог цикла

Что такое зацепка и как она связана с остальным — [../LOOP.md](../LOOP.md).
Порядок строк ниже — это ранг.

- **[B-01](B-01-response-metadata-dropped.md)** ждёт владельца, форма API (раунд 141) — метаданные ответа отбрасываются целиком
- **[B-02](B-02-wasm-android-promise-rejection.md)** ждёт владельца — wasm: необработанное отклонение промиса теряется на Android
- **[B-03](B-03-wasm-no-package-swift.md)** открыта, не срочно (раунд 182) — wasm: нет `Package.swift`, и при SPM плагина не будет вовсе
- **[B-04](B-04-isolate-future-timeout-unaudited.md)** открыта (раунд 67) — isolate: непроверенные места `Future.timeout`, цена — протёкший изолят
- **[B-05](B-05-isolate-null-credit-silent.md)** открыта — isolate: нулевой кредит неотличим от старого пира, сбой молчаливый
- **[B-06](B-06-websocket-lead-list-is-stale.md)** открыта, методическая — websocket: старый список зацепок протух, пакет надо пересканировать
- **[B-07](B-07-decision-close-on-protocol-error.md)** решена владельцем (раунд 190) — `closeOnProtocolError` по умолчанию `false` плюс крышка на количество нарушений
- **[B-08](B-08-decision-closed-transport-error-split.md)** закрыта (раунд 201) — расщепление типов ошибок на закрытом транспорте
- **[B-09](B-09-unfiled-grpc-compat-items.md)** открыта — не сведённые пункты «documented, not fixed» из приватной памяти

Следующий свободный номер: **B-10**.
