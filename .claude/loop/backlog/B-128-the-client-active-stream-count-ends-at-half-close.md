---
status: decided by owner (round 540)
round: 520
commit: 7cdaabf6
release: breaking
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: P-157
reason: "CONFIRMED — with the ceiling on the CLIENT only, four calls parked awaiting responses leave four slots free and a second batch of four is admitted in full. With the same policy on both sides the SERVER refuses those four, so the two sides count different intervals under one field name. Releasing later is hot-path stream accounting whose failure mode is refusing every subsequent call"
---

# B-128 — on the client, `_activeStreams` drops a call at half-close, not at completion

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`finishSending` and `_markFinished` call `_releaseStream`, so `maxActiveStreams` on a client counts only calls that have not half-closed; a unary or server-stream call awaiting its response is not counted.

## The shape

`packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart:588, 819-822, 844-847`.

## Why it matters

The client ceiling bounds request-sending, not outstanding calls; B-75 measured a
ceiling holding for calls started synchronously, which does not cover calls that
already half-closed.

## Witness a round would build

Ceiling 4; start 4 unary calls against a parked handler, let them half-close,
start 4 more. Expected today: admitted.

## Fix sketch

Release the slot on the terminal inbound frame or `releaseStreamId`, not on
half-close — or document which count is meant.

## Outcome (round 520) — CONFIRMED

```
ceiling on BOTH sides       4 refused with RESOURCE_EXHAUSTED
ceiling on the CLIENT only  0 refused — all eight calls completed
```

Four unary calls parked on a handler awaiting their responses, then four more against
a ceiling of four.

**The two runs together are the finding.** With one policy on both sides the refusals
appeared and this lead looked refuted — but they came from the SERVER, whose ceiling
does count the interval the name implies. `RpcChannelTransport.pair(policy:)` applies
one policy to both, so that run was ambiguous by construction: from the caller, a
server refusing at its own ceiling is indistinguishable from a client doing so.

With each side over a hand-built byte pipe carrying its own policy, the client refuses
nothing. **The two sides count different intervals under one field name.**

## DECIDED in the round-540 review: option 2 — count until COMPLETION

The slot is held until the call completes, not until half-close, so both sides count the same
interval and `maxActiveStreams` bounds client concurrency the way its name says. This also
settles the class: B-209 was answered the same way in the same review — a policy field names
what is OBSERVABLE, not what is convenient for the layer enforcing it.

**The failure mode runs the wrong way and the canary must be aimed at it.** A slot released too
early admits too much; a slot NEVER released refuses every subsequent call for the life of the
connection. So the witness (four parked calls must leave zero slots free, where today they leave
four) is the easy half — the load-bearing arm is a call that ends in each possible way
(completion, error, cancel, peer reset, transport close) and returns its slot every time. Round
536's own record notes the sibling shape: freeing a slot without stopping the work inverts the
limit.

**BREAKING.** A client that gets eight concurrent calls today at `maxActiveStreams: 4` gets
four. The CHANGELOG line has to name the ceiling as the thing that changed, not the accounting.

**Which event is the right end is still not established by measurement** — `releaseStreamId`,
the terminal inbound frame, or both — and that is the first thing the round settles. The note
below already names the candidates.

## Owner decision

1. **Document which count is meant.** Costs nothing, and it is demonstrably needed —
   the same field means "outstanding calls" on one side and "calls still sending" on
   the other. Round 507's `IRpcChannel.incoming` is the precedent for stating a
   contract instead of changing behaviour; round 518 left the same choice open.
2. **Release the slot later** — on `releaseStreamId` or the terminal inbound frame.
   This is stream accounting on the client's hot path, and the failure mode runs the
   wrong way: a slot released too early admits too much, a slot never released refuses
   every subsequent call for the life of the connection.

If (2), it needs something this round did not establish: which event is the right
release point for EACH call shape. The two candidates are not the same event — a call
cancelled locally never receives a terminal frame.

## Still unmeasured

**The streaming shapes.** A client-stream call holds its request stream open, so it
may already be counted for its whole life — which would mean the field's meaning
varies by shape as well as by side. Worth knowing before choosing a release point.
