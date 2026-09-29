---
status: closed (round 527)
round: 527
commit: c47683d3
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: P-161
reason: "CONFIRMED and fixed: the flow-credit pair now carries the same `_liveHere` guard as the sends. `getMessagesForStream` needs none, and the collision the lead describes is NOT closed by that guard — split to B-199"
---

# B-131 — websocket caller forwards flow-control and per-stream reads without `_liveHere`

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`deferFlowCredit`, `returnFlowCredit` and `getMessagesForStream` go straight to the current `_inner`; in peer mode the server's ids restart at 2 on every socket, so a late `returnFlowCredit(2, n)` from the old connection credits the new stream 2.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart:376-404`.

## Why it matters

Over-states a live stream's window by what a dead stream consumed.

## Witness a round would build

Peer mode, reconnect with a client-stream handler mid-consumption on the old
socket; read the new stream's credit.

## What round 527 measured

```
  arm                                  stale trailer   credit frames
  peer id, reconnect, peer REUSES it   DELIVERED       1
  peer id, reconnect, not reused       dropped         1
  own id, reconnect (space resumed)    dropped         1
  CONTROL peer id, no reconnect        DELIVERED       1
```

The `credit frames` column is this lead: `1` on every row, including the two where the
GUARDED `sendMetadata` was correctly dropped. Bench `../probes/P-161-does-a-stale-id-reach-the-new-socket.md`.

## Fix

Applied: the same `_liveHere` guard as the send paths, on `deferFlowCredit` and
`returnFlowCredit`. Rows 2 and 3 now read `0`.

**Two of the lead's three claims did not survive contact.**

`getMessagesForStream` needs no guard. A subscription is taken at call setup, so a stale
id can only get there from a call set up on a connection that no longer exists, and the
inner transport already answers that with a controller nobody feeds. Failing closed on a
DELIVERY path turns a wasted subscription into a handler that never receives a request.

And the guard does not fix the scenario the lead describes. `_liveHere` is membership, and
the peer's restarted numbering puts the reused id straight back — rows 1 and 2 differ only
in whether the peer reopened the number. Split to **B-199**, where the two fixes that do
work are both design changes.

## Owner decision

—
