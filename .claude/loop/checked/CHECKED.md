# Проверено — не перезапускать

Что такое негатив, чем он отличается от зацепки и почему свипы по детектору живут
не здесь — [../LOOP.md](../LOOP.md).

- **[C-01](C-01-sustained-load.md)** раунд 191, websocket, http2, isolate — обычная длительная нагрузка ничего не удерживает
- **[C-02](C-02-frame-codec-hostile-frames.md)** раунд 46, ядро и websocket — кадровый кодек против девяти враждебных кадров
- **[C-03](C-03-ping-flood.md)** раунд 77, http2 — флуд PING не дефект, удельная величина падает
- **[C-04](C-04-peer-chosen-stream-ids.md)** раунд 106, все транспорты — идентификаторы потоков, выбранные пиром
- **[C-05](C-05-inbound-security-parity.md)** раунд 103, http2 — респондер валидирует входящие метаданные
- **[C-06](C-06-lifecycle-apis-twice.md)** раунд 77, транспорты и http2-сервер — свип по API жизненного цикла
- **[C-07](C-07-outbound-backpressure-websocket.md)** раунды 60-61, websocket и ядро — исходящий backpressure ограничен кредитным окном
- **[C-08](C-08-cancel-reaches-handler-websocket.md)** раунд 137, websocket — отмена доходит до обработчика
- **[C-09](C-09-half-close-racing-trailers.md)** раунд 125, websocket — полузакрытие в гонке с трейлерами, 360/360
- **[C-10](C-10-ghost-stream-ids-from-peer.md)** раунд 123, websocket — призрачные идентификаторы от враждебного сервера
- **[C-11](C-11-reconnect-with-open-streams.md)** раунд 123, websocket — `reconnect()` с открытыми потоками и переиспользование id
- **[C-12](C-12-wasm-byte-pipe.md)** раунд 184, wasm — байтовый канал на обеих платформах
- **[C-13](C-13-wasm-load-close-cycles.md)** раунд 185, wasm — 40 циклов load/close
- **[C-14](C-14-wasm-real-guest-batteries.md)** раунд 187, wasm — три батареи против настоящего гостя
- **[C-15](C-15-grpc-listener-and-cancellation.md)** раунды 54 и 55, http2 — устойчивость слушателя и отмена от настоящего gRPC-клиента
- **[C-16](C-16-http2-caller-inbound-buffers.md)** раунд 52, http2 — входящие буферы вызывающего
- **[C-17](C-17-message-level-gzip.md)** ядро — gzip уровня сообщения ограничен
- **[C-18](C-18-leak-audit-coverage.md)** весь репозиторий — полный аудит течей, один дефект, остальное чисто

Большие полезные нагрузки и фрагментация (раунд 64) и серверный keepalive
(раунд 63) лежат в `../backlog/B-06-websocket-lead-list-is-stale.md`: там они
несут ещё и вывод про протухший список зацепок.
