---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b131_peer_id_reuse.dart
round: 527
commit: c47683d3
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
status: valid
---

# P-161 — does an operation for a stale stream id reach the new socket?

## Why it exists

Every operation the reconnecting wrapper forwards takes a bare stream id and resolves it
on whatever inner transport is current. Whether a given operation is guarded is not
readable from one call: the guard is membership in two sets that the reconnect clears and
the traffic refills, so the answer depends on what the peer did in between.

So the rig asks the SAME question of a guarded operation and an unguarded one, at the
same moment, for the same id, and varies the one thing the guard cannot see: whether the
peer reused the number.

## The harness

Two in-memory WebSocket pairs, the second handed to the wrapper's reconnect factory. The
client half of each pair COUNTS the frames written to it, so "did the stale call reach
the new connection" is a frame count rather than an inference about bookkeeping.

The per-stream window is configured and the connection pool is switched OFF, which makes
one returned credit above half the window exactly one grant frame and nothing else.

A real responder transport sits on the far end of each pair. That is not decoration: the
counted sink is a single-subscription controller, and with no reader the close at the end
of the run never completes.

## The numbers (round 527)

```
  arm                                  stale trailer   credit frames
  peer id, reconnect, peer REUSES it   DELIVERED       1
  peer id, reconnect, not reused       dropped         1
  own id, reconnect (space resumed)    dropped         1
  CONTROL peer id, no reconnect        DELIVERED       1
```

After guarding the flow-credit pair, rows 2 and 3 read `0` and rows 1 and 4 are
unchanged.

## Measures

Two things per arm: whether a guarded operation (`sendMetadata` with a marker header)
reaches the far end on the new connection, and how many frames the unguarded one
(`returnFlowCredit`) puts on it.

## Control

**Row 4, no reconnect at all.** Without it, `dropped` in rows 2 and 3 is equally
consistent with a broken pipe — the pair never carrying anything — as with a guard doing
its job.

**Row 2 against row 1** is the second control, and it is the one that matters: the same
stale id, the same call, differing only in whether the peer reused the number. That is
what shows the guard is defeated by reuse rather than absent.

**Row 3** pins the other id space: the wrapper resumes its own cursor across the
reconnect, so its own stale ids can never collide, and the guard holds there.

## What it establishes, and what it does not

Establishes: the flow-credit forwards reach the new connection for an id live on neither
set, and the send guard passes a stale operation whenever the peer has reused the number.

Does NOT establish that a deployment hits either. Nothing here drove a responder pipeline
whose consumption tail outlives a reconnect; the stale calls are made directly, which
measures the transport's contract rather than the odds of reaching it.

Does NOT measure the harm downstream of the grant. A peer clamps an incoming grant at its
own window, so the over-statement is bounded by one window per reused stream; this rig
does not read the peer's credit.

## Reading

rpc_dart_websocket — **puts the same question to a GUARDED operation and an
unguarded one, for the same stale id at the same moment**, and varies the one
thing the guard cannot see: whether the peer reopened the number. Read at the
WIRE, by counting frames written to the new socket, because the guard is
membership in two sets the reconnect clears and the traffic refills — every
bookkeeping observable sits downstream of that. The connection pool is
switched off so a returned credit is exactly one frame. Its control is an arm
with no reconnect, without which `dropped` is equally consistent with a pipe
that never carried anything.
