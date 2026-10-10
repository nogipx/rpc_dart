---
file: packages/transport/rpc_dart_http/.dart_tool/probe/r804_client_abort.dart
round: 804
commit: 4b9a575d
paths: [packages/transport/rpc_dart_http/lib/**]
status: valid
promoted: packages/transport/rpc_dart_http/test/a_cancel_reaches_the_handler_test.dart
---

# P-295 — when a closed connection reaches the server

## Measures

How long after a client closes or aborts its connection a Dart server in
the same process sees the close. A raw `ServerSocket` reads the request and
never answers; the client acts 200 ms after sending. Arms: `socket`
(`Socket.destroy`), `close` (`Socket.close`, a FIN), `io`
(`HttpClientRequest.abort`), `pkg` (`package:http` `AbortableRequest`).

```
  arm      client acts   server sees close   delay
  socket   222 ms        2297 ms             2.07 s
  close    223 ms        2324 ms             2.10 s
  io       242 ms        2347 ms             2.10 s
  pkg      224 ms        (not within 800 ms; not re-run at 3 s)
```

The same outside the Bash sandbox (`socket`: 2.10 s). The two earlier
probes beside it (`r804_abort_signal.dart`, `r804_socket_signal.dart`)
read a 1.5 s handler's answer as "dart:io does not read while a request is
handled"; the answer simply came before the 2.1 s close. Canary 2c of round
804 is what refuted that reading.

## Control

None separates the client's side from the server's: the delay is the same
for a destroy, a FIN and an HTTP abort, and an `nc` client in another
process was inconclusive (its own close time is unknown). What the probe
does establish is the floor for any cancel http can signal on this machine.
