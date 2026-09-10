---
round: 282
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-01
bench: P-31 — new
commit: yes
---

# Round 282 — metadata is never paced, and nothing else catches it

## Target

B-28, filed one round earlier with its probe design. Round 281 refuted the
credit-leak hypothesis by reading both ends and could not answer the
consequence; this builds the send-path bench that answers it.

## Hypothesis

Metadata is exempt from flow control at both ends, so a peer's metadata is never
paced. Round 281 predicted that after rounds 279 and 280 the queue's byte bound
would catch a flood — a hard failure where a payload flood is throttled, which
is wrong for a legitimate slow consumer but at least bounded.

## Before

A real transport pair, 64 KiB window, a consumer that has taken the stream and
paused, frames of 8 KiB each sent two ways.

```
arm       frames offered  sends completed  sender PARKED  connection error
payload              200                8           true              none
metadata             200              200          false              none
metadata            4000             4000          false              none
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/metadata_is_never_paced.dart`

The control parks at exactly 8 frames — 8 x 8 KiB is precisely the 64 KiB
window — so the bench measures the window rather than a coincidence.

**The prediction was half right and the wrong half is the finding.** Metadata is
indeed never paced: 4000 sends, 32 MiB, not one of them blocked. But **nothing
caught it either** — no connection error, no bound, at twice the queue's 16 MiB
ceiling.

## Mechanism

The queue's byte bound is on `_incoming`, the `BufferedBroadcastController`, and
it only queues while nobody is listening. These frames are routed to the
per-stream view from `getMessagesForStream`, which is a plain
`StreamController` — unweighed, uncapped, and buffering into Dart's own queue
because its subscriber is paused.

So the per-stream controller has never been bounded by a byte cap. For PAYLOAD
that is invisible, because flow control parks the sender long before the buffer
grows. **Flow control is the only thing standing in front of it, and metadata
walks past flow control.** Rounds 279 and 280 hardened the two budgets that DO
weigh; this is a third buffer that weighs nothing at all.

Cost to an unauthenticated peer: one stream, and as much metadata as it cares to
write. Bounded by bandwidth and nothing else.

## After

n/a — deliberately not fixed this round.

## Canary

n/a. The control carries it: the same bench, the same consumer, the same byte
count as payload, parks at the window.

## Gate

n/a — no code changed. `loop.py lint` green.

## Not fixed

An owner decision, and the two candidates differ in what they break:

1. **Charge metadata against the send window.** Symmetric with payload and it
   makes a metadata flood behave exactly like a data flood — throttled, not
   failed. It changes pacing for every existing client that sends metadata
   mid-stream, and `sendMetadata` becomes a call that can block, which it never
   has been.
2. **Bound the per-stream controller**, the way `BufferedBroadcastController`
   bounds the broadcast. Narrower, and it turns the flood into a stream-level
   failure rather than backpressure — the same hard-versus-soft trade round 281
   flagged, one layer down.

Both are behaviour changes on the path every transport shares, which is larger
than a round should take unilaterally. B-28 stays open with this measurement
attached rather than being closed.

Note what this does NOT claim: the payload path is fine, and the two budgets
rounds 279 and 280 fixed are fine. This is a third buffer, reached only when a
consumer is slow and the frames are metadata.

## Links

RPC-01 (`applied:` gains 282). Bench P-31, new — the first send-path bench here,
and the one to reuse for any "does this apply backpressure?" question. B-28
updated with the numbers. Rounds 279 and 280 are the two budgets this one is not
about, which is worth saying because all three look alike from a distance.
