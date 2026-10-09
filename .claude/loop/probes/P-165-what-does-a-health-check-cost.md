---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b136_health_check_noise.dart
round: 532
commit: a016a327
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart]
status: valid
---

# P-165 — what does a plain HTTP request to the websocket port cost?

## Why it exists

The noise and the answer are two different questions and a fix can trade one for the other, so
both are read from the same run. A server that went quiet by no longer answering probes would
score perfectly on the first and be worse overall.

## The harness

A real `HttpServer` behind `rpcWebSocketConnections`, an `RpcWebSocketServer` with an
`onConnectionError` counter, and a `LogController` subclass counting error-level records. Ten
plain `GET /healthz` requests in one arm, ten real WebSocket handshakes in the other.

**Counted inside the controller, not off a filtered record stream** — the level guard around a
log call cannot be seen downstream of the filter, because a filtered record is discarded either
way.

## The numbers (round 532)

```
  arm                            error logs   onConnectionError   peer saw
  10 plain GETs                  10           10                  400
  CONTROL 10 real handshakes     0            0                   upgraded
```

After the fix the first row reads `0  0  400` — the noise gone, the answer unchanged.

## Measures

Error-level log records, `onConnectionError` invocations, and the status code the peer actually
received. The third is the one that keeps the first two honest.

## Control

**Ten real handshakes.** Without them `0 errors` after a fix is equally consistent with a logger
that counts nothing, and the counter subclass is exactly the kind of thing that can silently
count nothing.

## What it establishes, and what it does not

Establishes: every non-upgrade request produced one error-level record and one
`onConnectionError`, because dart:io's `WebSocketTransformer._upgrade` sends 400 and then
completes with a `WebSocketException` that `bind` forwards to its OUTPUT stream — which is the
server's `connections` stream. A probe is indistinguishable from a real connection failure to
anything downstream.

Does NOT measure at a load balancer's real rate or duration. Ten requests in a loop show the
per-request cost; the operational claim (noise proportional to probe rate) is arithmetic on top
of it.

Does NOT cover the slow-body path. This probe's requests are ordinary GETs;
`a_refused_upgrade_has_a_deadline_test.dart` is what holds the bounded-drain behaviour, and it
is the test that caught this round's first attempt.

## Reading

rpc_dart_websocket — **reads the noise and the ANSWER from one run**, because
a fix can trade one for the other and a server that went quiet by not
answering would score perfectly on the first. Counts error records inside a
`LogController` subclass rather than off a filtered record stream — the guard
around a log call cannot be seen downstream of the filter. Its control is ten
real handshakes, without which `0 errors` is equally consistent with a counter
that counts nothing.
