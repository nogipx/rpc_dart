---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r731_stop_during_bind.dart
round: 731
commit: 41718b8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart, packages/core/rpc_dart_log/lib/src/log_server.dart]
status: valid
---

# P-242 — does a server stopped during its bind end up listening?

One probe per server, each at `.dart_tool/probe/r731_stop_during_bind.dart`
in its package (rpc_dart_http2, rpc_dart_http, rpc_dart_log). A free port,
start not awaited, `stop()` at once, then a TCP connect. Run with `melos exec
--scope=<package> -- fvm dart run .dart_tool/probe/r731_stop_during_bind.dart`.

## Measures

Whether the port accepts a connection once both calls settle.

## Control

`stop()` after `start()` completes:

```
  CONTROL stop after start   port accepts: false   (all three)
  stop during bind, before   port accepts: true    (all three)
  stop during bind, after    port accepts: false   (all three)
```
