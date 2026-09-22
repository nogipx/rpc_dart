---
file: packages/core/rpc_dart/.dart_tool/probe/response_pump_outlives_its_call.dart
round: 426
commit: 2eec94f2
paths: [packages/core/rpc_dart/lib/src/core/sink_pump.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/caller.dart]
status: valid
---

# P-96 — does a producer stop when its call ends, and on which endings

`fvm dart run packages/core/rpc_dart/.dart_tool/probe/response_pump_outlives_its_call.dart`.

Six arms. A handler feeds `responseSink` at one message per 5 ms while a
consumer reads everything, then the call ENDS one of five ways; the sixth is the
CALLER side. For another ending, add a `_responseArm` with a different `end`
callback — the harness is the argument.

## Measures

Messages the producer had pulled at the moment the call ended, and again 250 ms
later. The delta is the number: **+1 is a pump that stopped, +30-odd is one that
did not.** Counted inside the `async*` generator, so it is the producer's own
count and not the wire's.

It also reports whether `responder.done` fired, which is what says an ending is
*knowable* — an ending with no signal is a different problem from an ending
nobody watched.

## Control

Arm D ends the call through `responder.close()`, which cancels the subscription
directly, and arm E is the CALLER side that round 390 already fixed. Both read
+1 while the arms under test read +30-odd, so the instrument can see a pump that
stops.

```
                                before     after     responder.done
A  handler half-closes          +32        +1        true
A2 handler fails the call       +35        +1        true
B  the caller goes away         +34        +34       FALSE
C  the client transport dies    +33        +31       FALSE
D  CONTROL responder.close()    +1         +1        true
E  CONTROL caller side (390)    +1         +1        --
```

B and C are unchanged on purpose: no signal reaches a hand-built responder when
the peer leaves, so there is nothing for the pump to watch. In the library's own
path the pipeline closes the responder, which is arm D.
