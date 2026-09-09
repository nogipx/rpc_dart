---
status: open
round: 211
commit: 0d071c55
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/parked_waiters_drain.dart
reason: cost — the mechanism is not pinned; the obvious theory was measured and disproven, and the damage is bounded by an existing cap that is documented as failing open
---

# B-14 — one stale `_fcSendCredit` entry per parked-then-abandoned upload

Found by P-04 while answering B-13. Thirty client-stream uploads into a handler
that consumes nothing, each parking the sender before the answer arrives:

    handler drains (sender never parks)  sendCredit  0
    handler consumes nothing             sendCredit 30
    same, with _fcWake ablated           sendCredit  0

Exactly one entry per call, linear (6 calls gave 6), and only when the sender
actually parks and is then woken. Ordinary drained traffic returns to zero.

## Why it is not filed as a defect

`_fcSendCredit` is capped at `maxActiveStreams` by `_fcCanTrack`, and the cap's
own comment documents the behaviour at the ceiling: a stream arriving when the
map is full "simply gets no flow-control state, which leaves it unbounded rather
than stalled -- failing open on liveness, and bounded overall by the cap". So
this is bounded and the end state is a documented trade-off, attacked and held
in round 145.

What round 145 did NOT consider is the reachability. Its story is a hostile peer
flooding ghost ids; this is ordinary, successful, non-hostile traffic reaching
the same ceiling on a long-lived connection — 4096 parked-and-abandoned uploads,
after which `initialSendWindowBytes` silently stops seeding any new stream. That
window is worth 156.25 MiB against 4.05 MiB over a 20 ms link, so losing it is
not cosmetic.

## The theory that was measured and DISPROVEN

"The sender woken by `_fcForget` loops back into `_fcTryConsume`, finds no entry
and re-seeds." A fix closing that path — waking with a flag so the sleeper
returns instead of re-consuming — left the number at exactly 30. It was reverted
rather than shipped, because canary discipline says an unproven fix does not go
in. Do not re-try it without new evidence.

Diagnostic prints in `_fcTryConsume`'s seed branch and in `_fcForget` gave
`SEED 1, SEED 1, FORGET 1, FORGET 1, FORGET 1, FORGET 1` — every forget AFTER
every seed, and no seed afterwards. So the writer is not the seed branch.
`_fcOnGrant` also writes `_fcSendCredit`, is not gated on the stream being live,
and is the next suspect; it was not instrumented.

## What would settle it

Instrument `_fcOnGrant` the same way and re-run P-04 with one call. If the write
lands after the forgets, the fix is to refuse a grant for a stream that is no
longer tracked — which needs care, because `_fcOnGrant` legitimately creates the
entry for a live stream that has not sent yet.

## Owner decision

—
