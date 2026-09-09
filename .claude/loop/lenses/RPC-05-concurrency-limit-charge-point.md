---
refines: U-07
paths: [packages/core/rpc_dart/lib/**]
applies: RpcSecurityPolicy has fields capping concurrency
breaks: "one way a dead limit, the other way a DoS: an unbounded rise in handlers, or denial of service."
applied: [214, 215]
status: swept here (round 215, d0612f96) — every field that HOLDS state, see below
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
