---
status: open
round: 224
commit: ed1a54bc
paths: [packages/core/rpc_dart/lib/src/core/transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/watermark_survives_a_decorator.dart
reason: a breaking signature change, larger than round 224 was authorised to make; it moves an existing error from run time to compile time and fixes nothing currently broken
---

# B-21 — make the reconnect capability a compile-time requirement

Round 224 refuses a transport without `IRpcStreamIdSequence` at attach, so the
data loss is gone. The refusal is a **runtime** one: the developer learns on the
first run, from a `RpcClientDisconnected` and an error log.

The honest end state is a type:

```dart
abstract interface class IRpcReconnectableTransport
    implements IRpcTransport, IRpcStreamIdSequence {}
```

as `RpcClientConnection`'s `transportFactory` return type. A decorator author
then gets a compile error at the factory, pointing at the exact members to
forward, instead of a message at run time.

## Why round 224 did not do it

- **It is a separate breaking change**, on the signature rather than the
  behaviour, and the owner authorised the refusal and said in as many words not
  to smuggle this into it.
- Every first-party caller transport would have to declare the new interface.
  Mechanical, but it touches five packages rather than one.
- It fixes nothing that is currently broken: after round 224 the failure is
  loud, early and self-explanatory. This makes it earlier still.

## When to take it

The next major of `rpc_dart`, alongside whatever else breaks the signature.
Doing it on its own would spend a major version on a diagnostic improvement.

## Owner decision

—
