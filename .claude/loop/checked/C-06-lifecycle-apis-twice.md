# C-06 — Свип по API жизненного цикла

Коммит:     5bf4d34e
Пути:       packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**, packages/core/rpc_dart/lib/**
Область:    транспорты, http2-сервер
Контроль:   одиночный вызов каждого метода: состояние возвращается в исходное, значит дефект дал бы второй вызов

Раунд:      — (не перепроверено)

Свип чист. Это форма U-15, для которой в наборе ещё нет своей линзы — завести её
тому раунду, который снова возьмётся за жизненные циклы, и перенести этот статус
на неё.
