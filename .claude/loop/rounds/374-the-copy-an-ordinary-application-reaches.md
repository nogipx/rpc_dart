---
round: 374
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-65 — new
commit: yes
---

# Round 374 — the copy an ordinary application reaches

## Target

The last open thread in the owner's bidi goal, and the one round 371 named and
deliberately did not sweep into: `_pumpBidirectionalResponses`, the endpoint's
own relay, is a THIRD implementation of the job rounds 370 and 371 fixed on the
two sinks.

It matters more than either of them. The sinks are reachable only by building
`BidirectionalStreamCaller` / `BidirectionalStreamResponder` directly; this pump
is what an **ordinary application** reaches — an `async*` bidi handler
registered on a contract.

RPC-25, fourth application in a row, and the clearest instance of its shape yet:
three copies of one rule, two fixed by previous rounds and the third left
because nothing brings the difference to anyone's attention.

## Hypothesis

The pump does not forward its relay's pause to the handler, so an `async*`
handler runs to exhaustion whenever the consumer stops reading.

## Before

A caller that subscribes and immediately pauses, a 1 MB window, 16 KiB messages,
2000 offered, sampled at 900 ms, counted inside the handler's generator:

```
                 produced of 2000     MB
bidiPump           2000            31.3
serverStream         68             1.1     <- control
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/bidi_pump_backpressure.dart`
(P-65). The control is a server-stream handler on the same rig, whose relay
already forwards pause, differing by exactly that. It lands on the window.

## Mechanism

`_pumpBidirectionalResponses` relays the handler's stream through a controller
so teardown can cancel it, then drives it with `await for`. That loop pauses the
relay while `await responder.send(...)` is in flight — and nothing passed the
pause on, so the relay was an unbounded buffer between the handler and the wire.

`ServerStreamResponder` has the same relay for the same reason and DOES forward
it, with a comment saying why. Two files, no import between them, and the
analyzer sees two correct methods.

## After

```
                 produced of 2000     MB
bidiPump             68             1.1     <- 2000 -> 68
serverStream         68             1.1     <- control, unchanged
```

Exactly on the control, as in both previous rounds (P-61: 68 against 66; P-62:
68 against 68). `relay.onPause` / `onResume` forward to `handlerSub`, behind a
`torn` flag so neither can land on a cancelled subscription after teardown.

## Canary

`relay.onPause`'s body switched off in place:

    Expected: a value less than or equal to <300>
      Actual: <2000>
    the pump pulled 2000 of 2000 messages (31.3 MB) out of the handler while
    the consumer was not reading

A number, not a timeout. The GUARD — an ordinary bidi call still delivers all 40
messages in order — passed on both sides.

Witness: `test/streams/bidi_pump_bounds_its_handler_test.dart`.

## Gate

All four green: `melos run analyze`, `melos run test:unit --no-select`,
`melos run format:check`, `melos run license:check`. In the changed package
`fvm dart analyze lib` clean, `fvm dart test -j 8` **+1541 ~1**. Runs paced.

## Not fixed

**The REQUEST direction of the same pump** was not measured. This round's class
was the response relay named by 371; the request side reaches the handler
through `_pipelineFedRequestStream`, which is a different mechanism with its own
`deferFlowCredit` accounting, and measuring it is a separate bench. Named rather
than left implied.

## Links

- RPC-25 — the lens; `applied:` gains 374
- P-65 — the bench; the control is the sibling and it lands on the window
- Round 371 — named this copy and declined to widen into it
- P-61, P-62 — the two sinks, same rule, same numbers
