---
round: 450
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-15
bench: none — a read, nine greps over `lib/`; the evidence is which greps came back with more than one implementation
commit: yes
---

# Round 450 — eight held, one did not

## Target

**Not the top of the rank, and the reason is a measurement.** B-77 was next, and
was SIZED first: three harnesses (each layer is reachable only from its own wire,
and the existing raw http2 harnesses are caller-side while this is the responder),
12 rows, a new policy enum that must be added to the constructor AND `fromMap` AND
`toMap` or it becomes a fresh B-85, three call sites rewired, and http2 gaining a
check it has never had — which needs its own witness and canary rather than a
shared function. That is two to three rounds. The sizing is written into B-77 so
the next round starts from it instead of re-deriving it.

B-87 was taken instead: nine greps, explicitly a read, and finishable in one pass.
It is also the half where being wrong is most expensive — a false negative here is
a divergence nobody looks for again, because it is written down as settled.

## Hypothesis

The `ff930001` sweep listed nine things as already shared and reported none of
them. Nobody ever checked the list. At least one is wrong.

## Before

All nine, in one pass, because the defect being checked for is "nobody checked it"
and a partial pass reproduces it.

```
VERIFIED SHARED (8)
grpc-timeout              core/metadata.dart: one encode, one parse; 3 call
                          sites of encode, all calling the one function
grpc-message %-encoding    core/metadata.dart: encode + decode
-bin base64               core/metadata.dart only, normalisation included
drainUntilIdle            core/drain.dart, all three servers call it; the
                          COUNT is extracted too (B-63 item 2's half)
the 5-byte frame          core/protocol + parser. http2's `ensureGrpcFrame`
                          CALLS parseHeader/encode -- checked on purpose,
                          because B-78 describes it as parsing bytes itself
backoff                   core/resilience/backoff_policy.dart; the transports
                          mention it in COMMENTS only
wireStatusFor             core/errors.dart (+ platform_error_io.dart)
bufferedBytes             core only; its absence in http2 is B-79, a different
                          question from duplication

FALSE AS WRITTEN (1)
parity alignment          true of `RpcStreamIdManager` -- and http2 does not
                          use the manager at all
```

The parity rule has three homes:

```
core   resumeAfter.isOdd == isClient ? resumeAfter : resumeAfter + 1
http2  caller: streamId.isOdd ? streamId : streamId + 1, client-odd hard-coded,
       `_nextStreamId = 1`, `+= 2`
http2  responder: `_nextStreamId = 2`
```

## Mechanism

The sweep named the CLASS that owns the rule and stopped there. `RpcStreamIdManager`
does own it — round 360 made sure of that, and its comment says why. The entry is
false because the manager is not the only id allocator: http2 delegates real id
assignment to `package:http2` and keeps its own handle counter, so it never
touches the manager.

## After

n/a — no source change. Eight negatives recorded in `checked/C-49`; the false one
is `B-89`, per B-87's own instruction that such an entry gets its own number
rather than being folded back in.

## Canary

n/a. What stands in for it: the nine greps had to be able to come back non-empty,
and one did. Eight entries reading "one home" against one reading "three" is what
separates this from a search that could only ever agree. The second control is
B-63's checked list, preferred wherever the two overlap.

## Gate

No source changed, so the gate is the journal's: `loop.py lint` green.

## Not fixed

**B-89 is filed at its real strength and no more.** The http2 caller's hard-coded
client-odd is CORRECT for a class whose `isClient` is a literal `true`, so the two
rules agree on every input it can receive. Nothing was shown to bite. Its two
measurable questions are in the lead, and if both come back clean it closes as a
negative.

**The websocket and isolate transports were not read for a fourth id allocator.**
Both go through `RpcChannelTransport`, which uses the manager, so they inherit
core's rule — asserted from the dependency direction, not grepped.

## Links

- RPC-15 — re-measure the loop's own record; here the record is a sweep's
  unchecked negatives
- C-49 — the nine, verified
- B-89 — new, the one that was false
- B-87 — closed by this round
- B-77 — sized and deliberately not started; the sizing is in the lead
- B-63 — the checked version of roughly the same set, preferred where they overlap
