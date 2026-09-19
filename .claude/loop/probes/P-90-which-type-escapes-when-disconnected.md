---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/which_type_escapes_when_disconnected.dart
round: 405
commit: baa8f457
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
status: valid
---

# P-90 — which type escapes a disconnected transport

## Why it exists

Round 404 saw the same DISCONNECTED state come back as `StateError` on websocket
and `RpcStatusException` on http2 through the same endpoint API, and recorded it
without filing. This drives it, with the cheaper explanation ruled out first.

The websocket half is that package's copy of the same file; one probe cannot
import both transports.

## Measures

Per transport: the type that escapes a unary call through the public endpoint
API, the type `createStream()` throws directly, and `isClosed` — after the
server is gone.

## Control

**The `health()` gate, which is the whole design.** Each arm polls the
transport's own health until it stops reporting healthy, and PRINTS what it
says, before making the call that is supposed to hit the guard. Without it, "the
two transports behave differently" and "one of them had not noticed yet" are the
same output — the round-395 and round-399 trap in a new place.

And `while connected` is the pre-state row, so an arm that never worked at all
cannot read as a finding.

## The numbers (round 405)

```
transport   health     createStream()   a unary call          isClosed
websocket   degraded   StateError       StateError            false
http2       degraded   no throw         RpcStatusException    false
```

Both report `degraded`, so both reached the state. `createStream()` is the
decisive row: it calls `_ensureUsable` directly on both, and on http2 it hands
out an id on a dead connection.

## What it establishes, and what it does not

Establishes: the difference is not timing. The http2 caller's `_disconnected` is
set only by the keepalive failure path and by a failed `reconnect()`, so with
`pingInterval` off — the default — a dead connection never enters the state its
own guard exists to name. B-61.

Does not drive `pingInterval` ON, which the keepalive path suggests would close
the gap; nor the `rpc_dart_http` or isolate callers, neither of which carries
this sentence.
