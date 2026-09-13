---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/connect_headers_and_timeout.dart
round: 361
commit: cfecf7ec
paths: [packages/transport/rpc_dart_websocket/lib/**]
status: valid
---

# P-52 — what `connect()` can and cannot express

Two questions about `RpcWebSocketCallerTransport.connect`, each with its own
server: can a caller put a header on the upgrade request, and how long does the
open hang against a peer that accepts TCP and answers nothing. Add a header
question by adding a row; add a hang shape by changing the fake peer.

## Measures

**The headers half is read on the SERVER side** — a recording `HttpServer`
copies every request's headers — so the number is what crossed the wire, not
what the client believes it set. The timeout half is wall-clock milliseconds to
the open resolving, one way or the other.

## Control

For headers, two: `connect()` with no headers at all (must stay absent, or the
assertion is passing on some default), and the same header attached BY HAND
through `WebSocket.connect`, which proves the server and the probe agree about
what an arriving header looks like.

For the timeout, the arm with no bound is the control: whatever it reports,
`connect()` had none of its own.

```
a) route                        authorization
   connect(), no headers        ABSENT              control
   by hand, WebSocket.connect   [Bearer t0ken]      control
   connect(headers: ...)        ABSENT           -> [Bearer t0ken]
   after reconnect()            (not reachable)  -> [Bearer t0ken]

b) arm                          elapsed   outcome
   no connectTimeout            10016ms   STILL HANGING at the probe bound
   connectTimeout: 800ms        806ms     TimeoutException
```

**The `after reconnect()` row is the one that decides whether the feature is
usable at all.** A token that goes only on the first upgrade gives a transport
that authenticates exactly once, and the reconnect factory is built inside
`connect()` — so the probe has to drive `reconnect()` rather than stopping at
the first handshake.

The `10016ms` is the PROBE's own bound, not a measurement of how long dart:io
would wait: the point is only that nothing in the library stopped it.
