---
status: open
round: 386
commit: 2a5514ad
paths: [packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/sink_close_during_add_stream.dart
reason: cost — the only signal that the call ended is the response stream completing, and the CONSUMER owns that stream, so closing this is a design change rather than a small fix. Two cheap candidates were written and refuted by measurement
---

# B-54 — a bidi producer keeps running after the call has ended

Reported by the owner from a reading, measured in round 386. When the server
ends the call — a trailer, an error, a deadline — the caller's `requestSink`
keeps pulling its producer:

```
produced 11 when the call ended, 32 a quarter-second on
```

Every message after the end goes to `send()`, is caught, is logged at ERROR, and
the subscription resumes. An endless producer — a chat, a sensor feed, a
`Stream.periodic` — is an endless error log, and the work to generate each
message is spent for nothing.

`ClientStreamCaller.call(Stream)` does not have this: it races the request
stream against `_responseCompleter` with `Future.any` and cancels its
subscription in the `finally`. The endpoint bridge does not have it either: it
owns both subscriptions and cancels the request side in `cleanup()`.
`requestSink` is the third copy and the only one that cannot see the end.

## Two candidates, both refuted by measurement

Written, measured, reverted. Recorded so the next round does not pay again:

1. **Stop on the first send failure.** Never fires. C-35 measured that
   `caller.send()` does not throw — `CallProcessor.send` queues through
   `_transmitRequest`, whose callback ends in a bare catch and records
   `_requestSendFailure` instead of propagating.
2. **Gate the sink on `_processor.isActive`.** Never fires either: `isActive`
   stays TRUE after the server ends the call normally. The probe read 11 -> 32
   with the gate in place, unchanged.

Neither was shipped, because a branch that cannot execute is a line no witness
can cover (L-04).

## Owner decision

None needed to START — this is cost, not a trade. It is filed rather than fixed
because the two cheap routes are measured dead and the remaining one changes
`CallProcessor`'s surface (a `done` future) or the meaning of `_isActive`, which
several paths read. A decision is only wanted if that surface change is
unwelcome; otherwise the next round can take it with the witness that already
exists.

## Where to start

The real signal is `_processor.responses` completing or erroring, and the
CONSUMER owns that stream — it is single-subscription and handed out by the
`responses` getter. So the fix needs one of:

- a `done`-style future on `CallProcessor` that the sink can listen to without
  competing for the response stream (the responder already has exactly this:
  `BidirectionalStreamResponder.done`);
- or `_isActive` set on the normal end, which is a behaviour change to a flag
  several other paths read.

The witness is already written: the third arm of P-79. It needs `produced` to
stop climbing once the call ends, with the endless-producer arm as the shape
that makes the difference visible.
