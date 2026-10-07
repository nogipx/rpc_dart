---
status: closed (round 710)
round: 710
commit: 27650f07
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: .dart_tool/probe/parity_matrix.dart
reason: "measured — found by the transport matrix, group 7"
---

# B-258 — the window outgrows the stream buffer

## Seen

The per-stream queue was bounded by `effectiveMaxBufferedBytes`, derived as
`maxMessageLengthBytes + 5`, while the sender may send the whole 4 MiB window.
With `maxMessageLengthBytes: 64 KiB`, a websocket stream of 60 KiB items to a
reader spending 20 ms on each failed at item 3:

```
websocket  ERR at 3/50  Stream 1 buffered more than 65541 bytes un-consumed
memory, isolate, http2  all
```

Pre-existing: the same at `5170cd3c`, before round 709.

## Why it matters

Tightening the message limit is the first hardening step an operator takes,
and it silently broke every stream whose reader lags.

## Owner decision

2026-10-07: both. The derived queue bound covers the window plus one message
plus metadata; an explicit `maxBufferedBytes` below that shrinks the
advertised window instead, so the stream slows down rather than failing.
