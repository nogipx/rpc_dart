---
file: packages/core/rpc_dart/.dart_tool/probe/metadata_escapes_the_byte_bound.dart
round: 245
commit: 8d4d1e33
paths: [packages/core/rpc_dart/lib/src/core/buffered_broadcast.dart, packages/core/rpc_dart/lib/src/core/transport.dart]
status: valid
---

# P-21 — which dimension of a frame does the queue's byte bound see?

Fills an unlistened `BufferedBroadcastController` — the real one, with the
config every transport passes — past both of its bounds, and reports which one
stopped it. No sockets and no servers: the question is about accounting, so the
bench is the accounting.

## Measures

`pendingCount` after the fill, on the library's own controller, times the bytes
each frame was built with. Naming WHICH bound stopped it is what makes the two
arms comparable at a glance.

## Control

The same 64 KiB placed in `payload` instead of `metadata`; one variable.

```
arm        admitted  retained    bound that stopped it
payload      256      16.0 MiB   the byte bound         <- both, before and after
metadata    4096     256.0 MiB   the EVENT count        <- before
metadata     255      15.9 MiB   the byte bound         <- after
```

The payload arm is the control precisely because it does NOT move: it proves the
harness is reading the byte bound rather than "the controller stopped accepting
things".

> **A bound with an exempt dimension is not a bound.** Point this at any other
> `sizeOf` before trusting its cap: the question is not whether the weigher is
> called, it is whether anything the attacker controls weighs zero.
