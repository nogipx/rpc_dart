---
round: 600
commit: 48ce6026
paths: [packages/core/rpc_dart/lib/src/core/buffered_broadcast.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
scope: what the connection-wide _incoming queue retains with a consuming listener, a paused one, and none
---

# C-63 — a consumed connection queue holds nothing

B-217 measured 355 MiB on `_incoming`. That arm paused its `incomingMessages`
subscription, and a paused broadcast subscription buffers in dart:async.

```
arm        retained of 400 MiB minted direct objects
paused     +392 MiB    (the subscriber's own queue)
draining     +6 MiB    (what every endpoint does)
none       +376 MiB    (no listener: the library's queue, count-bound only)
```

## Control

`paused` against `draining`: one subscription, one difference.

## What it licenses

Not treating `_incoming` as an unbounded queue under any endpoint: the responder
pipeline and the caller's no-op drainer both consume.

## What it does not

The no-listener case: up to `maxPendingEvents` (4096) direct objects of any size.
Tracked in B-225 item 2 with the rest of "zero-copy weighs nothing".

`../probes/P-214-who-holds-the-connection-queue.md`,
`../rounds/600-the-queue-was-the-bench.md`.
