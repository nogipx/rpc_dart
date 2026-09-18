---
status: closed (round 389) — measured, and the consequence was worse than the reading
round: 386
commit: 2a5514ad
paths: [packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/caller.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/response_sink_swallows_the_error.dart
reason: bench — established by reading only. The probe written for it hangs before its first arm reports, and `measurement.md` item 10 says a bench that could not see the defect makes the claim INCONCLUSIVE rather than confirmed
---

# B-55 — the responder's responseSink turns a source error into an OK

> **CLOSED in round 389, and the title is wrong.** Measured on a rig that works
> (P-80): the client is not told OK, it is told **nothing, for ever** —
> `2 payloads, NEVER ENDED`. `addStream` does not close its target controller,
> so a failing source reaches `onError` (which only logged) and the controller
> stays open: `onDone` never runs, `finishReceiving()` is never called, no
> trailer is sent. The caller holds an open call and its state for the life of
> the process.
>
> Fixed by ending the call the way `ServerStreamResponder` already does —
> `wireStatusFor(error)` then `sendError(...)`. `NEVER ENDED` → `status 13`,
> with the clean-finish and explicit-`sendError` arms unchanged.
>
> **A note the round paid for**: the first witness asserted only
> `isNot(contains('ended OK'))` and PASSED against the unfixed tree, because
> "never ended" is also not "ended OK". It would have recorded a fix for a
> defect that was never there. The assertion is the exact string now.

Round 384's defect, mirrored onto the server. Reported by the owner from a
reading; **not measured**.

`BidirectionalStreamResponder.responseSink`'s `onError` logs and returns
(`responder.dart:156`). Nothing else happens, so the source's `onDone` follows
and runs `finishReceiving()` — a clean half-close. A handler written as

```dart
await responder.responseSink.addStream(somethingThatMayFail);
```

therefore tells the client the call **succeeded** when its own source failed
part-way. The client sees a short answer with an OK status and no way to know
the difference, which is the shape round 383 spent six rounds on from the other
end.

The caller's sibling now aborts and closes on this path (round 384, 386); the
endpoint pipeline never touches `responseSink` because
`_pumpBidirectionalResponses` relays a handler's error into its `await for`,
where it becomes a trailer. So this is the one copy still swallowing, and
`responseSink` is public — one of 171 exports.

The fix is almost certainly `sendError(...)` in `onError`, mirroring what the
caller does with `abort`, plus suppressing the `finishReceiving()` that would
otherwise follow. It is small; it is the MEASUREMENT that is missing.

## Why it is filed rather than fixed

`.dart_tool/probe/response_sink_swallows_the_error.dart` builds the low-level
pair the way `bidirectional_coverage_test.dart` does — a
`BidirectionalStreamResponder` on stream id 1 over `RpcChannelTransport.pair()`
— and hangs before printing its first arm, with the hang somewhere before the
opening `send` returns. Two bounded timeouts were added and neither arm
reported, so the rig, not the library, is what needs diagnosing first.

Shipping a fix here with no witness would be exactly what this loop refuses.

## Owner decision

None needed. This is a bench problem, not a trade: the fix is small and almost
certainly right, and what is missing is the measurement that would let it ship.
The next round diagnoses the rig first.

## Riding along: a dead branch in payloadResponses

`BidirectionalStreamCaller.payloadResponses` re-checks `grpc-status` in each
message's metadata and throws `RpcStatusException.fromTrailer`. But `responses`
is already piped through `_grpcStatusErrorTransformer`, which turns a non-OK
trailer into that same error one layer earlier — so the branch cannot be
reached. Cosmetic, and it should be deleted with a test that pins the
transformer's behaviour first, not on the strength of this reading.
