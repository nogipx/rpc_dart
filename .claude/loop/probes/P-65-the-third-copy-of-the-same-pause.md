---
file: packages/core/rpc_dart/.dart_tool/probe/bidi_pump_backpressure.dart
round: 374
commit: 9df8e772
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart]
status: valid
---

# P-65 — the third copy of the same pause

## Why it exists

Rounds 370 and 371 measured this job on the two sinks. Round 371 named a THIRD
implementation — the endpoint's own `_pumpBidirectionalResponses` — and did not
sweep into it, so that a subset would not be reported as the job. This is that
measurement.

It matters more than the other two: the sinks are reachable only on the caller
and responder classes directly, while this pump is the path an **ordinary
application** takes — an `async*` bidi handler registered on a contract.

## Measures

How many messages the pump pulled out of the handler's generator while the
consumer was not reading, counted inside that generator. Count and MB.

Rig: a caller that subscribes and immediately pauses, a **1 MB** window,
**16 KiB** messages, 2000 offered, sampled at 900 ms, through the ordinary
endpoint API.

## Control

A server-stream handler on the same rig in the same run, whose relay already
forwards pause (`relay.onPause = () => _handlerSubscription?.pause()`), and
which differs from the case under test by exactly that.

It reports **68 — 1.1 MB — the window**, unchanged before and after, so the
reading is of the mechanism and not of the timing.

## The numbers (round 374)

```
                 produced of 2000     MB
bidiPump           2000            31.3     <- before
bidiPump             68             1.1     <- after
serverStream         68             1.1     <- control, both runs
```

The fixed arm lands exactly on the control — the third time in three rounds
(P-61: 68 against 66; P-62: 68 against 68).

## What it establishes, and what it does not

Establishes: the endpoint's bidi pump created unbounded demand on an ordinary
`async*` handler, and the fix lands it on the sibling's value.

Says nothing about the request direction of the same pump, nor about latency:
`RpcChannelTransport.pair()` flattens that (P-58).
