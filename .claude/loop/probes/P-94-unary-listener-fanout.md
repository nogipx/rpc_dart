---
file: packages/core/rpc_dart/.dart_tool/probe/unary_listener_fanout.dart
round: 423
commit: 3f41ab67
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart]
status: valid
---

# P-94 — listeners on the connection, per parked unary handler

## Why it exists

`UnaryResponder._setupRequestHandler` listened to
`_transport.incomingMessages` — the whole connection's broadcast — and its first
act was to discard what was not its own:

```dart
if (id != 0 && message.streamId != id) return;
```

One listener per LIVE UNARY HANDLER, each invoked for every inbound frame. B-57
asks what that costs.

## Measures

How many times anything reads `transport.incomingMessages` while N unary
handlers are parked. A wrapping transport increments a counter on each read.

**A COUNT, not a duration.** The defect is O(N) invocations per frame, and a
wall clock on an in-memory pair measures the machine — an earlier record of this
shape (48 ms against 333) is a reading nobody can reproduce on other hardware.
The count is the same fact without the noise.

## Control

`listensToTransport: true` at the pipeline's `UnaryResponder` construction —
the pre-fix behaviour, one flag away, with nothing else differing.

```
parked handlers   with the fix   control (fix off)
      1                1                2
     10                1               11
     50                1               51
    200                1              201
```

Exactly N+1 in the control — the pipeline's own listener plus one per live
handler — against a flat 1. The arms differ by that flag and nothing else.

## What it does NOT measure

The per-frame COST of each listener. The count is the mechanism; how much a
discarded frame costs per handler is a separate reading, and round 423 did not
take it because the count already decides the question.

Nor the duty those subscriptions carried — that a transport error which does not
close the stream is still answered. That is
`one_listener_not_one_per_handler_test`'s GUARD, which passes on both sides of
the control, not this probe.
