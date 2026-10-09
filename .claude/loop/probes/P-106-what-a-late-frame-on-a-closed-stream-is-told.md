---
file: packages/core/rpc_dart/.dart_tool/probe/drain_refusal_ordering.dart
round: 454
commit: ea802346
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-106 — what a late frame on a closed stream is told

## Why it exists

Two refusals sit either side of one closed-stream guard and only the ceiling
explains its position. The variable is therefore the ENDPOINT's drain flag,
holding the arriving frame fixed.

## The harness

A channel pair, a responder with one unary method, and **one COMPLETE call first**
— that is what puts the id in the closed-stream set, and without it the arm
measures a fresh stream instead of a finished one. Then `markDraining()`, then a
metadata-only frame on that same id, delivered down the raw client transport.

Stream 1 is used deliberately: client ids are odd and this is the first call, so
the late frame is provably not a new stream.

The reading is the statuses the peer is sent AFTER the call completed, collected
off `client.incomingMessages`.

## The numbers (round 454)

```
                                      before fix              after fix
draining, late frame on a closed id   status=14 shutting down  NONE (ignored)
NOT draining, same frame              NONE (ignored)           NONE (ignored)
GUARD draining, NEW stream            status=14, status=14     status=14, status=14
```

## Measures

The grpc-status values delivered to the peer after its call finished. A count of
them matters as much as their presence: the guard arm reads TWO, which is how the
second defect (B-90) surfaced.

## Reused in round 467, with one new arm

B-90 came out of this bench's own GUARD arm and asked that the SIBLING refusal be
driven before anything was fixed. It now is:

```
                                       before      after
GUARD draining, NEW stream (2 frames)  [14, 14]    [14]
CEILING at 1, a 2nd call (2 frames)    [8,  8]     [8]
```

**The ceiling arm needs the client and the responder to hold SEPARATE policies.**
`RpcChannelTransport.pair(policy:)` configures both ends, and since round 463 the
caller's own `createStream` refuses at the ceiling first — so a shared policy
measures the client and reports it as the server. C-29's test note, four rounds
after the round that made it bite on every transport.

The occupying call is a metadata frame with NO payload: it never dispatches, so
the state stays live and holds the slot for the whole arm without a parked
handler.

## Control

Two, and the third arm is a GUARD rather than a control.

1. **The same frame with the endpoint NOT draining** — ignored, before and after.
   Only the drain flag differs between it and the witness, so the ordering is what
   produced the answer.
2. **A genuinely NEW stream while draining** must still be refused. Moving a
   refusal later is precisely the change that can disable it, so this arm is
   load-bearing: a drain that stops refusing new calls is not a drain.

## What it establishes, and what it does not

Establishes: the drain refusal, ordered before the closed-stream guard, answered a
trailing frame on a completed stream with a second terminal status; ordered with
the ceiling, it does not; and it still refuses new streams.

Does NOT establish anything about the double refusal in the guard arm. It reads
`status=14, status=14` on BOTH sides of the change, so it is pre-existing and
untouched — B-90.

## Reading

rpc_dart — varies the endpoint's DRAIN FLAG and holds the arriving frame
fixed. **One COMPLETE call first is the setup that matters**: it is what puts
the id in the closed-stream set, and without it the arm measures a fresh
stream instead of a finished one. Stream 1 on purpose, so the late frame is
provably not new. The third arm is a GUARD rather than a control — moving a
refusal later is the change that can disable it — and it is what surfaced
B-90, because the refusal COUNT matters as much as its presence
