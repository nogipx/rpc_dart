---
round: 247
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-15
bench: none
commit: no
---

# Round 247 — B-11's blocker still holds

## Target

B-11, under RPC-15 (re-measure your own record). The stale sweeps are done — 243,
244, 245 and 246 cleared the last four — and of what remains, B-22 and B-24 wait
on the owner, B-25 needs about 75 minutes of cycles per arm, B-10 and B-21 were
deferred by owner decision, and B-23 needs a call on where six architecture
notes belong. B-11 and B-09 are the two a round can take unaided.

U-21 says a deferral's BLOCKER ages separately from its number, and that
checking it is worth a round whichever way it comes out. This checked it.

## Hypothesis

The blocker — "the gap is made of latency and an in-memory pair zeroes it out" —
has dissolved, because the repository has gained a way to introduce latency
since round 206.

## Before

```
`implements IRpcChannel` test doubles in core                6
of those introducing any delay                               0
delayed / latency channel helpers anywhere in lib or test    0
```

The nearest starting point is `_ManualChannel`
(`test/transports/receive_path_hardening_test.dart`), where the test controls
delivery frame by frame — a latency channel is that plus a `Future.delayed` on
the send side, roughly twenty-five lines.

## Mechanism

n/a — the hypothesis was refuted. The blocker is intact: nothing in the tree
delays a byte pipe, so an endpoint-level bench for the connection-pool wedge
still has to build one first.

## After

n/a

## Canary

n/a

## Gate

Nothing shipped; the tree at 95c9f7bb is green.

## Not fixed

B-11 stays open, and the lead is updated rather than merely re-dated: the blocker
is CONFIRMED, and its cost is now concrete instead of a guess. What it needs is
a delayed paired channel (~25 lines, `_ManualChannel` as the model) plus the
endpoint-level drive that round 206 described — N pause-cancel server-streams,
then reading the pool through what a fresh stream can push before it parks.

**This round did not build that bench, and says so rather than recording a
fourth failed attempt it did not make.** Round 206 tried three shapes; the
honest state is three tried, none valid, and the fourth not yet attempted.

## Links

Lens RPC-15 (re-measure your own record) · lead B-11, blocker re-confirmed ·
the shape is catalog U-21 · the transport-level defect this would extend is
already fixed, with bench P-01 superseded by P-11.
