---
status: open
round: 658
commit: 7718fac6
paths: [packages/core/rpc_dart/lib/src/core/transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/lim_ids.dart
reason: "cost, low — needs ~2^30 calls on one RpcClientConnection (about 12 days at 1k calls/s); after the 31-bit id space wraps once, the watermark that keeps ids apart across reconnects (RPC-03) stops working for good"
---

# B-243 — stream ids collide across reconnects after the id space wraps

## Seen (limits review, round 658)

`transport.dart` restarts the cursor at 1 when no ids are active (it stays
pinned at the maximum while some are). `RpcClientConnection` keeps a watermark
that only moves up and seeds each new transport from it. After a wrap, the
dropped transport's cursor is below the watermark, so the new transport
replays exactly the ids the dropped one issued after it; once the watermark
sits at the maximum, every reconnect restarts at 1.

```
seed near the top   conn1 ids=[2147483643, 2147483645, 2147483647, 1, 3]
                    conn2 ids=[2147483643, 2147483645, 2147483647, 1, 3]   overlap: all five
seed 1001           conn1 ids=[1003..1011]  conn2 ids=[1013..1021]         overlap: none
```

The downstream harm -- a dead call's late teardown landing on a live call with
the same id -- is RPC-03's / B-199's, measured once ids collide; not re-driven
for this path.

Inside one transport the wrap is clean: 2000 rounds after it with long-lived,
abandoned and expired calls, `wrong=0 hangs=0`.

## What a round owes this

A watermark that survives the wrap: track the generation (wrap count) beside
the id, or reset the watermark when the transport reports a wrap, and a
witness that drives `resumeStreamIdsAfter` near the top across two reconnects.

## Owner decision

—
