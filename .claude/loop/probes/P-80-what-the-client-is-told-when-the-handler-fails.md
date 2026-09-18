---
file: packages/core/rpc_dart/test/streams/response_sink_error_reaches_the_client_test.dart
round: 389
commit: be9c9222
paths: [packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
status: valid
---

# P-80 — what the client is told when a bidi handler's source fails

## Why it exists

B-55 was filed unmeasured in round 386 because the probe written for it hung
before its first arm reported. This is that measurement, on a rig that works.

## The rig, and why the first one failed

`bidirectional_coverage_test`'s pair: `RpcInMemoryTransport.pair()` through
`NoZeroCopyTransport`, a low-level `BidirectionalStreamResponder` on stream id
1. The endpoint pipeline never touches `responseSink` —
`_pumpBidirectionalResponses` relays a handler's error into its own `await for`,
where it becomes a trailer — so the low-level responder is the only way to reach
this path at all.

Round 386's version built the same shape on `RpcChannelTransport.pair()` and
hung before its opening send returned. **Lives in `test/` rather than
`.dart_tool/probe/` for a plain reason**: the working rig needs
`test/utils/transport_wrappers.dart`, and the witness and the bench are the same
three arms.

## Measures

One string per arm: how many payloads reached the client, and how the call
ENDED.

**With an OVERALL deadline, not a per-event `Stream.timeout`.** That is the
whole reason it can see this defect: the answer turned out to be *never ended*,
and a per-event timeout re-arms on every payload, so it reports a timeout that
reads like any other slow call. The overall deadline makes "NEVER ENDED" a
first-class result.

## Control

Two arms that must not move: a handler that finishes cleanly (`ended OK`) and
one that calls `sendError` itself (`status 13`) — the paths that already worked,
so the fix cannot be credited with them. Both stayed green under the canary.

## The numbers (round 389)

```
arm                              before                    after
source fails after 2 messages    2 payloads, NEVER ENDED   2 payloads, status 13
handler finishes cleanly         2 payloads, ended OK      unchanged
handler calls sendError          2 payloads, status 13     unchanged
```

## What it establishes, and what it does not

Establishes: a handler driving `responseSink.addStream(source)` whose source
fails used to leave the client with no ending at all, and now ends the call with
the mapped status.

**And one thing about the witness itself.** Its first version asserted only
`isNot(contains('ended OK'))` and PASSED against the unfixed tree, because
"never ended" is also not "ended OK". A witness that cannot name the wrong
answer cannot tell it from the right one; the assertion is the exact string for
that reason.

Does not cover the endpoint pipeline (which never uses this sink), a source that
errors and keeps going, or the responder's request direction.
