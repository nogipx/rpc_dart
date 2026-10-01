---
file: packages/core/rpc_dart/.dart_tool/probe/b217_who_holds_the_connection_queue.dart
round: 600
commit: 48ce6026
paths: [packages/core/rpc_dart/lib/src/core/buffered_broadcast.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid (round 600)
---

# P-214 — who holds the connection-wide queue

## Why it exists

B-217: is the 355 MiB on `_incoming` the library's queue or the subscriber's?

## The harness

`memoryPair`, 400 minted 1 MiB direct objects on one stream, no per-stream
consumer. Arm argument: `paused`, `draining`, `none`. One arm per process; RSS.

## The numbers (round 600)

```
paused     +392 MiB   delivered 0
draining     +6 MiB   delivered 401
none       +376 MiB   delivered 0
```

## Measures

RSS retained while nothing per-stream consumes.

## Control

`paused` against `draining` — the same subscription with and without the pause.
