---
file: packages/core/rpc_dart/.dart_tool/probe/sink_close_during_add_stream.dart
round: 386
commit: 2a5514ad
paths: [packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
status: valid
---

# P-79 — close() while an addStream is running, and the producer after the end

## Why it exists

The owner audited round 384's fix from the source — no Dart to run it — and
reported that `StreamController.close()` throws while an `addStream` is active,
so `BidirectionalStreamCaller.close()` never reaches `_processor.close()`, and
round 384's `abort(...).whenComplete(close)` routes that throw into the zone.
This measures it.

## Measures

Three things, everything inside `runZonedGuarded` so an unhandled async error is
COUNTED rather than killing the probe:

- whether `close()` throws, and with what, while an `addStream` still pulls;
- how many zone errors round 384's `onError` path produces;
- how far a producer gets after the server has ended the call.

## Control

**The sharpest control here is the PRODUCER SHAPE, and it is the whole point.**
Two arms run the identical code path and differ only in whether the source
survives its own error:

```
source keeps going (a controller that addError's and stays open)  1 zone error
source ends at its throw (an async*, round 384's own witness)     0 zone errors
```

An `async*` that throws ENDS there, so its `addStream` is already complete when
`close()` runs. That is why round 384 shipped green. A bench arm can be void for
the FIX as well as for the defect (L-15, one level up).

The `close()` arm has its own control in the test file beside it: closing with
no `addStream` running, which stays green on both sides of the canary.

## The numbers (round 386)

```
close() while an addStream is active     StateError  ->  no throw
onError path, source keeps going         1 zone error -> 0
onError path, source ends (384's arm)    0            -> 0
producer after the call ended            11 then 32   -> unchanged (B-54)
```

## What it establishes, and what it does not

Establishes: `close()` threw while an addStream ran and no longer does; round
384's error path could reach the zone and no longer can; and the producer keeps
running after the call ends, which this round did NOT fix.

Does not establish anything about the responder's `responseSink` — a second
probe was written for that and hangs before its first arm reports, so B-55 rests
on a reading rather than a measurement. Nor about the endpoint bridge, which
owns its own subscriptions and was never in this class.
