---
file: packages/core/rpc_dart/.dart_tool/probe/detach_cancel_throws.dart
round: 235 — the validating round
commit: ec94fd7a
paths: [packages/core/rpc_dart/lib/src/resilience/**]
status: valid
---

# P-14 — does a throwing onCancel abandon the transport?

An `RpcClientConnection` over a fake `IRpcTransport` (which must also implement
`IRpcStreamIdSequence`, or round 224's guard refuses it at attach) whose
`incomingMessages` controller has an `onCancel` that throws. `connect()`, then
`forceReconnect()`, then `dispose()`. Run it with
`melos exec --scope=rpc_dart -- fvm dart run
.dart_tool/probe/detach_cancel_throws.dart`.

The whole run is inside `runZonedGuarded`, which stands in for the ROOT zone an
application would have: an error that reaches it is one that would end the
isolate.

## Measures

Four numbers, all on the library's side. **Transports built vs closed** —
counted in the factory and in the fake's own `close()`, so `leaked` is what the
proxy failed to release. **Unhandled zone errors**, which is the crash. And
whether **`dispose()` threw**, which is whether the application can clean up at
all.

## Control

The same rig, same calls, differing by ONE thing — whether that `onCancel`
throws:

```
  control        built=2 closed=2 leaked=0 unhandled=0 disposeThrew=false
  cancel THROWS  built=1 closed=0 leaked=1 unhandled=1 disposeThrew=true

  after the fix
  control        built=2 closed=2 leaked=0 unhandled=0 disposeThrew=false
  cancel THROWS  built=2 closed=2 leaked=0 unhandled=0 disposeThrew=false
```

`built=1` in the defect arm is itself a finding rather than a setup difference:
the second transport was never built because `forceReconnect()` runs
`detach().then(...)` with no `onError`, so a rejected detach skips the reconnect
entirely.

Lens: `../lenses/RPC-16-check-before-await.md`.
