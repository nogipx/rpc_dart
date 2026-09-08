# C-18 — Полный аудит течей

Коммит:     5bf4d34e
Пути:       packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**
Область:    весь репозиторий
Контроль:   найденный в том же аудите дефект: течь видна теми же счётчиками, значит они способны её показать

Раунд:      — (не перепроверено)

Один дефект найден, остальные измерения чистые. Записано, чтобы не гонять аудит
целиком заново: брать из него отдельные измерения по мере надобности.
