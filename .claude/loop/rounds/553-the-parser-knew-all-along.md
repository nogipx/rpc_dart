---
round: 553
verdict: FIXED
packages: [rpc_dart]
lens: RPC-08
bench: P-181 — new
budget: probes 1/5, canaries 4/5
commit: yes
release: changelog
---

# Round 553 — the parser knew all along

## Target

B-126's owner decision, **attempt 3**: take the unary lifecycle change so a transport that
splits a gRPC frame across transport messages is tolerated. Two attempts were built and
reverted; the second named exactly what a third must do first, and that is where this one
starts.

> A third attempt must take that distinction FROM the parser, which knows whether it holds a
> partial frame, and not from the emptiness of its result. Adding that is the first step, not
> the fix.

Lens RPC-08: unary was the one shape that could not take what both streaming shapes take.

## Hypothesis

`RpcMessageParser` already distinguishes the two cases internally — every limit clears its
buffer before throwing, so leftover bytes mean "incomplete" and nothing else. If that is true,
the blocker is a missing getter rather than a missing design.

## Before

```
CONTROL whole frames        unary got:64   server stream got:64   client stream got:64
each frame split in two     unary status 13   server stream got:64   client stream got:64
```

Round 518's measurement, with the two witnesses sitting SKIPPED in the tree since 547.

## Mechanism

**The blocker was a getter.** `holdsPartialFrame` is `_state.available > 0`, and it is exact
because every refusal path in the parser calls `clear()` before it throws: a refused frame
leaves nothing held, an incomplete one does. Eight cases pin it, including both refusal paths
and a chunk holding one whole frame plus the start of another.

On that, four parts:

- the unary responder RETURNS "still incomplete" instead of throwing INTERNAL, keeping the
  per-stream state (which owns the parser) alive;
- the pipeline hands over every buffered pre-bind message rather than `.first`;
- a later data frame on a stream still awaiting its request is routed to that responder;
- a peer that half-closes mid-frame is answered INVALID_ARGUMENT.

**The answer is RETURNED, not left on the state.** Round 547's trap was reading "still
arriving" from per-stream state that the `finally` had already removed, so a COMPLETED call
skipped its teardown. A return value cannot be read after the fact.

**And one predicate carries the whole design: `isAwaitingRequest` asks the PARSER, not the
pipeline's bookkeeping.** The bookkeeping stays true while a later fragment is being
processed — the request is running then, not waiting — and answering the peer on that reading
closes the responder out from under its own handler. Which is silent, because a closed
responder writes nothing. P-181 is what found that; see below.

## After

```
WITNESS a fragmented request is answered                     got:64
a peer that stops mid-frame gets a STATUS, not a hang        status 3
a LATE half-close mid-frame also gets a status               status 3
GUARD whole frames still work                                got:64
GUARD a REFUSED frame is not reported as a truncated one     status 8, 'max: 1029'
GUARD the streaming shapes are unaffected                    got:64
```

Bench `../probes/P-155-does-unary-survive-a-fragmented-frame.md`, reused; tracer
`../probes/P-181-which-branch-took-the-fragment.md`, new.

**The refusal guard is the arm that reverted attempt 2**, and it is the one that may never go
green by accident: a 64 KiB request against a responder configured at `maxMessageLengthBytes:
1024` answers RESOURCE_EXHAUSTED naming `max: 1029` — the buffer bound derived from that field
— and not `status 3 'closed mid-message'`. The two policies are separate objects and only the
RESPONDER's is tightened, so the caller sends what its peer will refuse.

**P-181 is why this round converged.** Three statuses had already been read and none said where
the second fragment went. Tracing every record showed it was delivered AND parsed with no
answer after it — which moved the question from routing to "what silently dropped the answer",
and the only silent exit in that method is a closed responder.

## Canary

**Four, one per load-bearing part, and two of them changed the design.**

```
A. the wait removed (`parser.holdsPartialFrame` forced false)
   WITNESS a fragmented request is answered
     Expected: 'got:64'  Actual: 'status 13: Failed to extract message from payload'
   The original defect, verbatim. Both witnesses fail.

B. the pipeline's end-of-stream answer removed
   FIRST RUN: ALL SIX PASSED.
   a LATE half-close mid-frame also gets a status
     Expected: a string starting with 'status 3'
       Actual: 'status 4: Deadline ... exceeded'      (after removing the third site)

D. the routing of a later fragment removed
   WITNESS a fragmented request is answered
     Expected: 'got:64'
       Actual: 'status 3: Request stream closed mid-message'
```

**Canary B passing is the round's most useful result.** It meant a half-close was being answered
at THREE sites — dispatch, the end-of-stream handler, and the fragment feed — and whichever won
a race answered. The feed's copy was reachable for no ordering the other two do not cover, so it
is gone, and each ordering now has exactly one answer site. Only then did canary B fail, and it
fails on the one arm that distinguishes them.

It also forced a new arm. Both half-close orderings existed in one test shape — the fragment
carrying its own end-of-stream — where the dispatch already knows the peer finished. A half-close
arriving AFTER the responder begins waiting is a different branch, so `lateEnd` sends a bare
`encodeEndOfStream` 50 ms later.

**C is the one that did not fire**, and it is recorded in the code as unwitnessed: draining the
pre-bind buffer a second time. See `## Not fixed`.

## Gate

```
melos run analyze               SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select SUCCESS   15 packages; rpc_dart 1859 passed, 1 skipped
melos run format:check          SUCCESS   0 changed
melos run license:check         SUCCESS   2134 / 2134
```

`1847 passed, 3 skipped` became `1859 passed, 1 skipped`: the two witnesses unskipped, plus the
late-half-close arm, the refusal guard and the parser's eight cases.

**One existing assertion changed, and it is a behaviour change rather than a test fix.**
`unary_responder_parser_state_test` sent a frame header promising 100 bytes with 4 and pinned
`INTERNAL`; it now reads `INVALID_ARGUMENT`. The peer half-closed with a frame it never
finished, so the new status is the accurate one — and that test's own comment calls the arm
"expected and not the bug", which is how the old status came to be pinned there. Its real
subject, that the next stream is not poisoned, still passes.

`test:web` was not run: this is pure control flow with no dart2js exposure, and the machine is
above B-215's load precondition.

## Not fixed

**The pre-bind drain loop is UNWITNESSED and kept on judgement**, stated in the code. Disabling
its second iteration changes no test. What it guards is visible in the code rather than in an
arm: `_processResponderMessage` appends to the same buffer while this path awaits, and it cannot
route the message itself because the flag it keys on is not set until the dispatch returns. Three
lines, and the failure mode is a hang.

**Only the channel transports are exercised.** The witness needs a hand-written fragmenting
channel because no shipped transport fragments — http2 keeps a per-stream parser, the frame
channel reassembles, HTTP/1.1 buffers the body — which is the reachability reading round 547
recorded and this round did not redo. A third-party transport is the audience.

**A peer that sends half a frame and then nothing at all is still bounded only by its deadline.**
`halfOpenStreamTimeout` is cancelled at dispatch, and this fix dispatches. That limitation is
already written on the policy field and is not made worse here, but it is now reachable by one
more route.

**The zero-copy unary branch is untouched**: a direct object cannot be fragmented, and
`handleDirectMessage` breaks out of the feed loop.

## Links

Lead `../backlog/B-126-unary-assumes-one-message-per-transport-frame.md` — CLOSED after
three attempts.
Bench `../probes/P-181-which-branch-took-the-fragment.md` — new.
Bench `../probes/P-155-does-unary-survive-a-fragmented-frame.md` — reused.
Round `547-the-second-revert.md` — the attempt that named this round's first step.
Round `518-the-fix-that-turned-an-error-into-a-hang.md` — the hang a partial version produces.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [553]`.
