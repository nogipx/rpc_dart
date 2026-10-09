---
file: packages/notify/rpc_notify/.dart_tool/probe/r766_stalled_subscriber_ws.dart
round: 766
commit: 5cf99515
paths: [packages/notify/rpc_notify/lib/src/server/notify_service_server.dart, packages/notify/rpc_notify/lib/src/stream_distributor.dart, packages/notify/rpc_notify/lib/src/repository/in_memory_notify_repository.dart]
status: valid
---

# P-266 — what the notify server holds for a paused subscriber

## Measures

The server (`InMemoryNotifyRepository` + `NotifySubscribeResponder` behind
`RpcWebSocketServer`) runs in this process; the subscriber is a child process
over WebSocket that subscribes with the generated caller and then pauses its
subscription. The server publishes N distinct 64 KiB events (env `N`).
Printed: how many events the responder took from the repository stream (a
counting `map` between them), `droppedEvents` after the fix, and the SERVER's
RSS growth (L-21: the process that owns the buffer).

Arms (argv[0]): `paused`, `reading`.

`r766_stalled_subscriber.dart` beside it is the one-process first form; its
RSS mixes both sides and it only showed the growth was unbounded (1000 ->
+89 MiB, 4000 -> +267 MiB).

## Control

The `reading` arm: the responder takes all N and the server's RSS does not
grow with N.
