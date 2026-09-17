---
file: packages/core/rpc_dart/.dart_tool/probe/response_sink_backpressure.dart
round: 371
commit: 3edb3535
paths: [packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart]
status: valid
---

# P-62 — does the handler run ahead of the wire?

## Why it exists

The mirror of [P-61](P-61-does-the-producer-run-ahead-of-the-transport.md), which
round 370 named as the obvious next target and deliberately did not sweep into,
so that a subset would not be reported as the job. P-61 measures demand the
library puts on the APPLICATION's producer; this measures demand it puts on the
HANDLER's.

## Measures

How many messages the library pulled out of the handler's producer while the
consumer was not reading, counted inside that producer. Reported as a count and
as MB.

Rig: a caller that opens the stream and immediately pauses its subscription, a
**1 MB** flow-control window, **16 KiB** messages, 2000 offered, sampled at
900 ms.

`responseSink` is reachable only on `BidirectionalStreamResponder` itself, so
that arm builds the responder directly — the endpoint pipeline drives its own
pump and does not use the sink.

## Control

`ServerStreamResponder`, on the same rig in the same run, driven through the
ordinary endpoint API. It already forwards pause to the handler
(`relay.onPause = () => _handlerSubscription?.pause()`), and differs from the
case under test by exactly that.

It stops at **68 messages — 1.1 MB**, the window, and reports the same number
before and after the fix. That is what makes the reading a measurement of the
mechanism rather than of the timing.

## The numbers (round 371)

```
                 produced of 2000     MB
responseSink       2000            31.3     <- before
responseSink         68             1.1     <- after
serverStream         68             1.1     <- control, both runs
```

The fixed arm lands exactly on the control, which P-61's request-side fix also
did (68 against its sibling's 66).

## What it establishes, and what it does not

Establishes: the responder created unbounded demand on the handler, inside the
server process, driven by a consumer that simply stops reading — and the fix
lands it on the sibling's value.

Does not establish anything about a direct `responseSink.add()`, unbounded by
the `StreamSink` contract, nor about the endpoint pipeline's own bidi pump,
which does not go through the sink.
