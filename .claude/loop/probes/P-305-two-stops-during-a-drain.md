---
file: packages/transport/rpc_dart_http/.dart_tool/probe/r822_two_stops.dart
round: 822
commit: 6bf5b187
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart]
status: stale (526c8d52)
promoted: packages/transport/rpc_dart_http/test/graceful_drain_on_stop_test.dart
---

# P-305 — two stops during a drain

## Measures

`r822_two_stops.dart <stops>` (http; the websocket copy is
`packages/transport/rpc_dart_websocket/.dart_tool/probe/r822_two_stops.dart`):
a call is in flight to a handler that answers after 1 s, then `stops`
concurrent `stop(drainTimeout: 3 s)` calls. Prints when each returned and
the call's outcome.

```
  server      stops   returned at (ms)     call
  http        1       878                  ok   (control)
  http        2       890, 2               ok
  websocket   1       868                  ok   (control)
  websocket   2       844, 1               ok
  after the fix:
  http        2       894, 894             ok
  websocket   2       850, 850             ok
```

The same witness is in the websocket and http2 packages'
`graceful_drain_on_stop_test`.

## Control

One stop: it returns when the drain ends.
