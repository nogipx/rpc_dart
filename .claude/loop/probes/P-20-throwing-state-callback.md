---
file: packages/core/rpc_dart/.dart_tool/probe/state_callback_kills_the_zone.dart
round: 242
commit: d1723a5e
paths: [packages/core/rpc_dart/lib/src/resilience/**]
status: valid
---

# P-20 — what a throwing user callback costs on the reconnect path

Runs `RpcClientConnection` inside `runZonedGuarded`, drives
`connect() -> forceReconnect() -> dispose()`, and counts what escapes. Point it
at any other user-supplied callback on this class by moving the throw.

## Measures

Two numbers on the library's side, not the probe's: errors delivered to the
zone's handler, and transports the FACTORY was asked to build. The second is
what turns "noisy" into "dead" — a client that never built a transport is not
connected, and nothing says so.

## Control

The same run with a callback that returns normally; one variable, the throw.

```
arm                     unhandled  transports built
control                     0            2
onStateChanged throws       1            0     <- before
onStateChanged throws       0            2     <- after
```

> **Count what the callback PREVENTED, not just what it emitted.** The zone
> error is the obvious damage and the smaller one: an unhandled async error is
> fatal in the root zone, but the same throw also aborted the connect loop
> before it built anything, and no state, log or exception says so.
