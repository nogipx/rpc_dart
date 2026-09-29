---
status: decided by owner (round 540)
round: 527
commit: c47683d3
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: P-161
reason: "owner decision — CONFIRMED and measured; the two fixes that work are both design changes with a per-frame cost, and RPC-03 round 218 already measured that the cheap one cannot work"
---

# B-199 — a stale teardown for a REUSED peer stream id is delivered to the live call

Split out of B-131 in round 527, which closed B-131's own half. Measured, with
controls: `P-161`.

`RpcWebSocketCallerTransport` guards every send with `_liveHere(streamId)` — membership in
the set of ids minted on this connection, or the set the peer minted on it. The reconnect
clears both. For ids THIS side mints that is sound: `resumeStreamIdsAfter` carries the
cursor across, so the old and new id spaces are disjoint and a stale number is never a
live one.

**The peer numbers its own streams and restarts at the bottom on every socket.** Its first
frame on the reused number puts the id straight back into `_peerStreamIds`, so a teardown
still in flight for the call that HELD that number passes the guard and acts on the call
that holds it now.

## What was measured

```
  arm                                  stale trailer   credit frames
  peer id, reconnect, peer REUSES it   DELIVERED       1
  peer id, reconnect, not reused       dropped         0
  own id, reconnect (space resumed)    dropped         0
  CONTROL peer id, no reconnect        DELIVERED       1
```

Row 1 against row 2 is the finding: the same stale id, the same call, differing only in
whether the peer reopened the number. Row 4 is the control that makes `dropped` mean a
guard rather than a dead pipe; row 3 pins the id space where the guard does hold.

(The `credit frames` column is B-131, fixed in the same round. Rows 2 and 3 read `1`
before that fix.)

## Why it matters

A stale `sendMetadata` with `endStream` is what a cancellation notice and a responder's
trailer both look like, so the live call is terminated by another call's teardown. The
transport's own doc lists the rest of what a stale id does on a live stream: frees its
`maxActiveStreams` slot, drops its flow-control credit and wakes its parked senders past
their window, and clears the entry that tells a truncated response from a complete one.

Reachable in peer mode with nothing exotic — an application that reconnects on drop while
a handler is still answering an inbound call.

## Witness a round would build

Peer mode over a real socket: an inbound call in flight, the socket dropped, the peer
reopening the same number, and the old call's teardown landing after. `P-161` drives the
transport directly; this would drive the pipeline.

## Fix sketch — and why neither option is cheap

**Not a generation ledger keyed on the id.** RPC-03 round 218 measured this: once the
numbers collide, tagging by id cannot tell the dead caller's operation from the live one's,
and refusing to overwrite the tag drops the LIVE call's own teardown instead.

**Translate peer ids into the wrapper's own space.** The wrapper already intercepts every
inbound frame and every outbound send, so it can map an inbound peer id to an id of its own
that never repeats, and map back on the way down. That is what makes peer ids disjoint
across reconnects exactly as the cursor does for this side's own. Cost: a map lookup per
frame in both directions, and every forward in the wrapper has to participate.

**Or refuse the situation instead of detecting it**, which is how round 224 closed the
same shape for the outbound direction: make the peer-initiated state of a dropped
connection unreachable before the new one can mint anything, so a late teardown finds
nothing to act on.

## Owner decision

**Make the dropped connection's peer state unreachable before the new one can mint
anything** — the third option, not the id translation. Taken in the round-540 review.

So NOT the per-frame map lookup: the cost of translating every peer id in both directions
on the priority transport was the reason to prefer this, and round 224 already closed the
same shape this way in the OUTBOUND direction, which makes it a known pattern here rather
than a new design.

**What the round that carries this out owes.** The failure mode of "unreachable" is the
opposite of the one being fixed: an inbound call torn down slightly earlier than today, and
an answering handler that must get a STATUS rather than silence. So the witness is not only
"the stale teardown no longer lands" — it needs an arm where a handler is mid-answer when
the socket drops, asserting what it receives. Round 518's lesson applies directly: a fix
that turns an error into a hang is worse than the error.

Round 224's own record is the reading to start from; `_idsOnThisConnection`'s doc already
describes the outbound half of this mechanism.
