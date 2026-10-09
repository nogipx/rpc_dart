---
file: packages/core/rpc_dart/.dart_tool/probe/b127_timers_per_call.dart
round: 519
commit: eb42e917
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/core/rpc_dart/lib/src/contracts/call_scope.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
status: valid
---

# P-156 — how many timers does one call arm?

## Why it exists

The lead names three arming sites plus a `.timeout()` per disposer. No one of them
can report the total, and counting by reading means trusting that the reading found
them all. A Zone sees every `Timer` whoever creates it.

## The harness

`runZoned` with `createTimer` and `createPeriodicTimer` hooks, incrementing live
counters. Twenty calls per arm, divided out.

**Everything runs inside ONE zone, endpoints included, and that is the whole
correctness of the rig.** A stream subscription creates its timers in the zone it was
registered in — so building the endpoints outside the counted zone leaves every
RESPONDER timer in the root zone, uncounted. This lead is about a SERVER call, so
that is exactly the half that would have gone missing.

The first version did that and reported `1.0 timers/call` for unary, with the
deadline apparently costing nothing. The counters are zeroed after an in-zone warm-up
instead, because the first call on a connection arms things belonging to the
connection rather than to the call.

## The numbers (round 519)

```
unary, WITH a deadline               4.0 timers/call
CONTROL unary, no deadline           2.0 timers/call
server stream, WITH a deadline      14.1 timers/call
CONTROL server stream, none          9.1 timers/call
```

So a deadline costs **2 timers on a unary call and 5 on a server stream**, on top of
a floor of 2 and 9.

## Measures

Timers created per call, counted at the only place that sees all of them. No periodic
timers appear on any arm.

## Control

**The no-deadline arms**, and they are what make the figure attributable. The lead is
about "three timers for one deadline", so the quantity of interest is the DIFFERENCE;
an absolute count of 4 would leave open how much of it the deadline caused.

They also produce the more surprising number: a server-stream call arms nine timers
before any deadline is involved.

## What it establishes, and what it does not

Establishes: multiple timers are armed per deadline, as the lead claims — 2 for
unary, 5 for server stream — and the per-call floor is itself 2 and 9.

**Does NOT confirm the specific count of three.** It is 2 on unary and 5 on streaming,
so the lead's number is not a constant and the shape matters.

Does NOT locate WHICH site arms which timer. The Zone counts them; attributing them
needs a stack capture per creation, which was not done. So the fix sketch's "one
deadline owner per call" cannot be checked against this measurement for how many it
would remove.

Does NOT measure token listeners, the lead's other half, which are not timers and are
invisible here.

## Reading

rpc_dart — a Zone is the only place that sees every `Timer` whoever creates
it, so counting by reading would mean trusting the reading found them all.
**Everything runs inside ONE zone, endpoints included, and that is the rig's
whole correctness**: a subscription creates its timers in the zone it was
registered in, so endpoints built outside it leave every RESPONDER timer
uncounted — which is the half the lead is about. The first version did that
and reported `1.0 timers/call` with the deadline apparently free. Its controls
are the no-deadline arms, which make the figure attributable — and which
produced the larger finding, a nine-timer floor on a server stream.
