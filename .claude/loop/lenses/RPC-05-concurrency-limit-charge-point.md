---
refines: U-07
paths: [packages/core/rpc_dart/lib/**]
applies: RpcSecurityPolicy has fields capping concurrency
breaks: "one way a dead limit, the other way a DoS: an unbounded rise in handlers, or denial of service."
applied: [214]
status: confirmed (round 214) — swept for every field that HOLDS state except the pre-method byte budget, see below
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
    maxBufferedBytes       NOT SWEPT -- see B-16

Round 214's result, six calls churned against a ceiling of three, then a burst
of twelve:

    normal 3, throw 3, cancel 3, deadline 3    releases in place
    normal 0, throw 0, cancel 0, deadline 0    _releaseHandlerSlot ablated

> **Charging is only half a lifecycle.** The original evidence was about WHERE a
> limit is charged; the other question, and the one round 214 asked, is whether
> every way a call can end gets back to the release. Enumerate the endings, not
> the happy path.
