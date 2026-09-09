---
file: packages/core/rpc_dart/.dart_tool/probe/pending_queue_counts_events.dart
round: 236 — the validating round
commit: 6840be09
paths: [packages/core/rpc_dart/lib/src/core/**, packages/core/rpc_dart/lib/src/rpc/transports/**]
status: valid
---

# P-15 — which dimension does the pending queue bound?

Fills `BufferedBroadcastController`'s unlistened queue, directly and through
`RpcChannelTransport.pair()`, and reports the queue's own `pendingCount`, the
exact retained bytes, and RSS. Run **one arm per process** — the arm name is the
first argument, the payload size in KiB the second:

    fvm dart run .dart_tool/probe/pending_queue_counts_events.dart tx-nolisten 64
    arms: unit-listen unit-nolisten tx-listen tx-nolisten

## Measures

`pendingCount` — the library's own counter, and the primary witness because it
is exact. Retained bytes are computed from it and the known payload size. RSS is
corroboration only.

**Two RSS traps this bench was rebuilt to avoid, both of which produced a wrong
number first.** Running all four arms in ONE process made arm 2 read *-25 MiB*,
because it was reusing arm 1's garbage — hence one arm per process. And
`Uint8List(n)` is zero-filled memory the OS need not commit: touching only
`[0]` left 1 GiB of retained payload reading as *+46 MiB*. Where the exact
figure is available, prefer it; if RSS is the only witness, page the buffer in.

## Control

The arms differ by ONE thing — whether a listener is attached:

```
  tx  listener      delivered=4096   RSS   +2 MiB
  tx  NO listener   delivered=0      RSS +549 MiB     <- before
  tx  NO listener   delivered=0      RSS  +58 MiB     <- after the byte bound
```

And the dimension itself, same arm with the payload varied — the count never
moves while the bytes scale linearly, which is the finding:

```
   16 KiB each   pending=4096   retained   64 MiB
   64 KiB each   pending=4096   retained  256 MiB
  256 KiB each   pending=4096   retained 1024 MiB
```

Lens: `../lenses/RPC-17-limit-fires-after-residency.md`.
