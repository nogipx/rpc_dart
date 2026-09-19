---
file: packages/transport/rpc_dart_isolate/.dart_tool/probe/what_a_dead_worker_looks_like.dart
round: 407
commit: 566ad1cb
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
status: valid
---

# P-91 — what a caller is told when its isolate worker is gone

## Why it exists

Round 405 built this measurement for websocket and http2 and found the two
disagree. The isolate had no row, and it is the transport with neither
`_disconnected` nor `reconnect()` — its whole lifecycle is
`spawn() -> (transport, kill)`.

## Measures

Per way of dying: what a call already IN FLIGHT gets, `isClosed` afterwards, and
what a later call gets.

The arms come from reading rather than guessing: `spawn()` registers an
errorPort and an exitPort, and after startup both do the same thing —
`unawaited(hostChannel?.close())`. So there are two distinct death signals plus
the host's own `kill()`, and the question is whether they look alike to a
caller.

## Control

`first` — an ordinary call before anything dies, on every arm. An arm whose
worker never worked cannot read as a finding.

And `kill` is the control on the other two: the host's own teardown reaches
neither port, so if it produced a different answer the difference would be
attributable to the port rather than to the death.

## The numbers (round 407)

```
mode    first        in flight               isClosed   a later call
throw   served(ok)   RpcStatusException(14)  true       RpcStatusException(14)
exit    served(ok)   RpcStatusException(14)  true       RpcStatusException(14)
kill    served(ok)   -                       true       RpcStatusException(14)
```

Consistent across all three: **UNAVAILABLE, and the transport closes.**

## What it establishes, and what it does not

Establishes the isolate's row, and that its three deaths are indistinguishable
to a caller — including an uncaught error thrown from a timer after the
handler's own frame is gone, which is the one that reaches `errorPort` rather
than becoming a call error.

`isClosed: true` is the right answer HERE and not a disagreement with the other
two: a killed isolate is terminal, there is nothing to reconnect to, and the
remedy is to spawn another. The socket transports stay `false` because they can
recover.

Does not drive the worker dying mid-STREAM rather than mid-unary, nor the web
(`isolate_transport_web.dart`) half, which is a different file.
