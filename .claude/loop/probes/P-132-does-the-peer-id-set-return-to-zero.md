---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b103_peer_ids_grow.dart
round: 494
commit: b27c9594
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
status: valid
---

# P-132 — does the peer-id set return to zero?

## Why it exists

`_peerStreamIds` holds streams the PEER minted and this side is still answering.
That is a statement about an invariant, not about a size: on an idle connection
the set must be EMPTY. So the bench does not look for a leak, it asks the
invariant.

## The harness

A real `RpcWebSocketServer`, a caller transport built through the CONSTRUCTOR
rather than `connect()` — only the constructor takes `platformHandlesPing`, which
is what forces the app-level heartbeat on the VM, i.e. puts the rig on the path a
browser is on.

Two arms, each paired with a control that must read zero:

- 100 ms heartbeat, 3 s idle, against no heartbeat and the same idle time.
- 50 calls cancelled at 20 ms against a handler that answers at 250 ms, against
  50 calls that complete normally.

**The set's size had to be exposed to be measured**: `health()` on this wrapper
delegated to the inner transport, which cannot see either of the wrapper's own
sets. `idsOnThisConnection` and `peerStreamIds` are in the details now — the same
move round 452 made for three http2 maps, and for the same reason.

## The numbers (round 494)

```
                          before          after the fix
heartbeat 100ms for 3s    peer 0 -> 29    0 -> 0
no heartbeat, 3s idle     peer 0 -> 0     0 -> 0     <- control
50 cancelled calls        peer 0 -> 50    0 -> 0
50 completed calls        peer 0 -> 0     0 -> 0     <- control
```

## Measures

The size of `_peerStreamIds` read from `health().details`, before and after a
period of activity. One entry per heartbeat interval and exactly one per
cancelled call are the two rates; the invariant is the zero.

## Control

Each arm's own paired run: the same rig with the heartbeat off, and the same 50
calls completing instead of cancelling. Both read `0 -> 0` before and after, so
the growth belongs to the heartbeat and to the cancel, not to the connection or
to the rig.

**And the fix needs an INVERSE control, because after it every arm reads zero** —
which is also what a transport that had stopped recording anything would read.
`peer_ids_return_to_zero_test.dart`'s guard drives a real reverse call through
`RpcPeerEndpoint` and blocks inside the handler, so the count is read while the
peer's stream is open: it must be `1`, then `0` once answered.

## What it establishes, and what it does not

Establishes: the set grew without bound at one entry per heartbeat and per
cancelled call, and both sources are ordinary traffic.

Does NOT measure the second consequence directly — that each entry makes
`_liveHere` true for a dead id, so the stale-id guard is inverted for exactly the
ids the connection has finished with. That follows from `_liveHere`'s two-line
body and is not separately witnessed here.
