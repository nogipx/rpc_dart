---
refines: U-07
paths: [packages/core/rpc_dart/lib/**]
applies: RpcSecurityPolicy has fields capping concurrency
breaks: "one way a dead limit, the other way a DoS: an unbounded rise in handlers, or denial of service."
applied: [214, 215, 245, 266]
status: confirmed (round 245)
---

# RPC-05 — Where a concurrency limit is charged

## Shape

A new limit charges the resource at the wrong point of the lifecycle.

## Detector

For every `RpcSecurityPolicy` field, where exactly it is checked: stream
admission, handler entry, dispatch.

## Ask

Charging at entry — is it a no-op against a burst? Charging at admission — does
it deny service to half-open streams?

## Evidence

30 calls past a ceiling of 3 when charged at entry; 8 metadata-only frames
refused every call for 60 s when charged at admission. Only dispatch works.

**The origin, imported from private memory after round 235.**
`maxActiveStreams` does not bound how many handlers RUN; it bounds live stream
STATE, and the two coincide only while handlers cooperate. Dart cannot preempt a
running `async` function, so a deadline cancels the token and then falls back to
`_cleanupStream` after a 2 s grace — which frees the stream state AND the
admission slot. For an uncooperative handler the first is right and the second is
not: the work continues with its slot back in the pool. Against
`maxActiveStreams: 4`, one call every 250 ms with a 40 ms deadline, **37
concurrent handlers after 20 s and still growing linearly**, while
`activeResponders` read 3-4 the whole time. Closed in round 114 by
`maxConcurrentHandlers` (default null, opt-in, charged at dispatch): 37 -> 4 on
the same attack.

## Round 245 — the limit that exempts a dimension

`security_policy.dart` had not changed since the 215 sweep, so the field half of
the detector had nothing to look at. The defect was in a limit that is not a
policy field: `BufferedBroadcastController`'s byte bound weighs
`RpcTransportMessage.bufferedBytes`, which counted the payload only.

    arm        admitted  retained    bound that stopped it
    payload      256      16.0 MiB   the byte bound
    metadata    4096     256.0 MiB   the EVENT count     <- before
    metadata     255      15.9 MiB   the byte bound      <- after

> **Ask WHAT a limit charges, not only WHERE.** The exemption was justified in a
> comment — metadata "is small and bounded by the policy's header limits" —
> which is true per frame and false in aggregate at `maxMetadataBytes` x 4096.
> A bound with a dimension the peer controls and the weigher ignores is not a
> bound. Bench `../probes/P-21-metadata-escapes-the-byte-bound.md`.

> **Saturating the connection HIDES it, and that is a trap for any admission
> limit here.** With the table permanently full, later calls are rejected before
> dispatch: 43,908 calls in 14 s produced exactly 8 handlers against
> `maxActiveStreams: 8`, so a load test reports the ceiling holding. PACING past
> the reclaim grace is what defeats it.

**Both neighbours of the right charge point are measurably wrong, in opposite
directions**, which is why this lens exists: handler ENTRY reads as the more
precise semantic and is a no-op against a burst (found only over a REAL
transport — the paced core test stayed green); stream ADMISSION is a denial of
service, because a stream is half-open from its opening frame until dispatch, so
8 metadata-only frames refuse every call for the whole `halfOpenStreamTimeout`.
That second one was found by attacking the round's own fix one round later.

**The matching WHERE question is the release wrapper's placement** (round 116).
It sat on the innermost user handler, inside middleware and interceptors, so work
OUTSIDE the handler was released with the stream: an interceptor parked on an
auth lookup gave **2 interceptors live against a ceiling of 1**, accumulating
exactly like the handler case. It now wraps the whole `handleUnary` /
`handleClientStream` / `handleServerStream` / `handleBidirectionalStream` call at
all 8 dispatch sites.

> **Three separable halves, so three canaries, and each isolates cleanly:**
> ceiling never refuses -> 3 witnesses fail; released with the stream -> only the
> abandoned-call witness fails; never released -> the ATTACK witness stays green
> while ordinary traffic fails ("call 2 was refused; a slot is leaking"). A
> one-sided canary would have shipped that ratchet.

> **When a new assertion fails, check the FIXTURE before the code.** The first
> version of the interceptor test parked the interceptor and used a handler that
> also parks, so the chain could not unwind and "the slot comes back" failed for
> an unrelated reason.

## Which fields this detector actually covers

Round 214 enumerated all sixteen. **Most cannot suffer this shape at all**:
`maxMessageLengthBytes`, `maxHeaders`, `maxMetadataBytes`, `maxHeaderNameBytes`,
`maxHeaderValueBytes`, `maxMethodPathLength`, `maxMessagesPerChunk` and
`closeOnProtocolError` are pure predicates — checked at a point, holding
nothing, so there is no release to get wrong. Narrowing the detector to the
fields that HOLD state is most of the work.

    maxConcurrentHandlers  round 214, clean, ablation-validated (P-06)
    the four fc fields     rounds 206-213, exhaustively; 212 fixed a leak
    maxActiveStreams       round 212, every counter pinned back to zero
    halfOpenStreamTimeout  round 205, 20 parked streams reclaimed to 0
    the pre-method budget  round 215, clean, two controls (P-07); its ceiling
                           is maxMessageLengthBytes

**`maxBufferedBytes` is NOT one of these** — round 214 said it was, and that was
wrong. It is the gRPC parser's reassembly ceiling in `parser.dart`,
`if (_state.available > _maxBufferedBytes) throw`: a threshold read off the
buffer's own occupancy, with no separate counter that can desync from it. It
belongs with the pure predicates. Corrected in round 215.

Round 214's result, six calls churned against a ceiling of three, then a burst
of twelve:

    normal 3, throw 3, cancel 3, deadline 3    releases in place
    normal 0, throw 0, cancel 0, deadline 0    _releaseHandlerSlot ablated

> **Charging is only half a lifecycle.** The original evidence was about WHERE a
> limit is charged; the other question, and the one round 214 asked, is whether
> every way a call can end gets back to the release. Enumerate the endings, not
> the happy path.

Round 215 adds the reading half of that. The pre-method budget's `endStream`
ending holds its bytes and looks exactly like a leak, and is not one — it is the
reorder deferral, bounded by `halfOpenStreamTimeout`. Two controls were needed to
say so: the same run with a short timeout, and an ablation of the release.

> **A held resource is not a leaked one.** Before calling a non-zero counter a
> leak, find the bound that is supposed to release it and shorten THAT. If the
> number goes to zero, you have found a policy, not a defect. Recorded as C-20.
