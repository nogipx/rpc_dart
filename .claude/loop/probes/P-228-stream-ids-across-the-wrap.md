---
file: packages/core/rpc_dart/.dart_tool/probe/lim_ids.dart
round: 661
commit: 018fa1bb
paths: [packages/core/rpc_dart/lib/src/core/transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: valid
---

# P-228 — stream ids across the wrap

## Why it exists

B-243: the reconnect watermark (RPC-03) was the MAX cursor any transport issued.
After the 31-bit id space wraps that max is the top of the space, and a transport
seeded from it restarts at 1.

## The harness

Part A, one channel-pair transport seeded near the top, 12 unary calls: with and
without a server stream held open across the wrap, plus a low-seeded control.
Prints the cursor after each call. Part B, `RpcClientConnection` over fresh pairs:
seed the live transport, 5 calls, `forceReconnect`, 5 calls, print both id lists
and their overlap.

## The numbers

```
round 658 / 661 before
  A2 wrap, long-lived   cursor ... 2147483647, 2147483647, 2147483647 (pinned)
  B WITNESS near top    conn1 [2147483643, 2147483645, 2147483647, 1, 3]
                        conn2 [2147483643, 2147483645, 2147483647, 1, 3]  overlap 5
  B CONTROL low         conn1 [1003..1011]  conn2 [1013..1021]  overlap 0
round 661 after
  A2 wrap, long-lived   cursor ... 2147483647, 1, 1, 1 (the recycled id)
  B WITNESS near top    conn2 [5, 7, 9, 11, 13]  overlap 0
```

## Measures

The ids each transport issued, read from `lastIssuedStreamId` after each call.

## Control

The same sequence seeded at 1001, where no wrap happens: overlap 0 before and
after. A1 (wrap with nothing held open) and A3 show every call answered either way.

## What it establishes, and what it does not

Establishes whether ids are disjoint across one reconnect after a wrap. Does NOT
drive the downstream harm (a dead call's teardown landing on a live call), which
is RPC-03's and B-199's, measured once ids collide.
