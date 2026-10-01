---
round: 554
verdict: FIXED
packages: [rpc_dart]
lens: RPC-08
bench: P-155 — reused
budget: probes 0/5, canaries 1/5
commit: yes
release: changelog
---

# Round 554 — one rule, where the parser is

## Target

B-216, found by round 547's own witness arm and left open through two rounds: **a peer that
half-closes mid-frame is answered on unary and left to its deadline on a server stream.** Round
553 fixed the unary half at the pipeline, which is why the lead says the fix does not reach the
other shapes — their responders are bound to a message stream and the pipeline has nowhere to
notice.

Taken now because the apparatus is warm and round 553 built the mechanism this needs: a parser
that will say whether it holds a partial frame.

Lens RPC-08: one pipeline, three shapes, and the ending each gives a peer differs with nothing
saying so.

## Hypothesis

The three shapes diverge because each decides separately, at a different layer. If the rule is
placed where the PARSER is — the one component all three share — they cannot disagree.

## Before

```
peer stops mid-frame
   unary         status 3: Request stream closed mid-message: the last gRPC frame is incomplete
   server stream status 4: Deadline exceeded
   client stream got:0
```

Re-measured at this sha with `P-155`'s `truncate` arm, not cited from the lead. The unary column
is round 553's; the other two are what this round is about.

**`got:0` is the one worth looking at twice.** The call SUCCEEDS and the handler is told the peer
sent nothing, where in fact it sent an incomplete something. Better than a hang and worse than a
status: nothing anywhere reports a problem.

## Mechanism

`StreamProcessor` owns the parser and is the single thing all three shapes' request sides run
through. It closed its request controller at a half-close without asking the parser anything, so
the buffered fragment died with the stream — and since nothing else can see those bytes, unless
it is said there it is never said at all.

`_endRequests()` now raises INVALID_ARGUMENT into the request controller before closing it when
the parser holds a partial frame. Nothing else changed: the server-stream responder already
answers an error on its request stream (a duty an earlier round added for a different cause), and
a client-stream handler's `await for` throws, which its responder already answers.

**Both endings route through the one helper**, because a half-close reaches a processor two ways
— as a frame carrying end-of-stream, and as the bound message stream simply finishing. Left
apart, the answer would depend on the shape of the feed rather than on the request.

## After

```
peer stops mid-frame
   unary         status 3: Request stream closed mid-message: the last gRPC frame is incomplete
   server stream status 3: Request stream closed mid-message: the last gRPC frame is incomplete
   client stream status 3: Request stream closed mid-message: the last gRPC frame is incomplete
```

Bench `../probes/P-155-does-unary-survive-a-fragmented-frame.md`, reused unchanged. Its other
three blocks — whole frames, each frame split in two, fragments reordered ahead of their metadata
— read `got:64` on all three shapes before and after.

Three guards in the tree: whole frames work on every shape, a FRAGMENTED request works on every
shape (`got:64 / got:64 / got:1`), and round 553's refusal arm still answers RESOURCE_EXHAUSTED.
The middle one is the direction that matters most here — holding a partial frame must not leak
into a call whose frames do arrive, just in pieces.

## Canary

```
the error at half-close removed (`holdsPartialFrame` forced false)

WITNESS a server stream answers a mid-frame half-close
  Expected: a string starting with 'status 3'
    Actual: 'status 4: Deadline ... exceeded'
WITNESS a client stream does not report a truncated request as empty
  Expected: a string starting with 'status 3'
    Actual: 'got:0'
```

Both defects back, each with its own message, and nothing else failing — including unary, which
is what confirms the lead's claim that the two fixes are independent.

**The witness was SPLIT to get that.** As one test it stopped at the server-stream assertion and
the client-stream regression went unobserved — a single test cannot show two failures, and these
are two different ones.

## Gate

```
melos run analyze               SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select SUCCESS   15 packages; rpc_dart 1862 passed, 1 skipped
melos run format:check          SUCCESS   0 changed
melos run license:check         SUCCESS   2136 / 2136
```

No existing test moved. `1859 -> 1862` is the two split witnesses plus the fragmented-shapes
guard.

`test:web` not run: pure control flow, no dart2js exposure, and the machine is above B-215's load
precondition.

## Not fixed

**The bidi shape is unmeasured.** It runs through the same `_endRequests`, so it is fixed by
construction and by nothing else — `P-155` has no bidi column and this round did not add one.
That is the same gap B-218 records for round 552's half of this seam, and it belongs there.

**A peer that sends half a frame and then nothing at all is still bounded only by its deadline**
on every shape. This answers a half-close; it does not invent an idle-stream timeout, which
`halfOpenStreamTimeout`'s own doc explains cannot be safe by default.

**The zero-copy path has no parser and needs none** — a direct object cannot be fragmented — so
`holdsPartialFrame` is false there and the behaviour is unchanged.

## Links

Lead `../backlog/archive/B-216-a-server-stream-hangs-on-a-truncated-frame.md` — CLOSED.
Lead `../backlog/B-218-the-other-half-closes-are-unmeasured.md` — the bidi column goes here.
Bench `../probes/P-155-does-unary-survive-a-fragmented-frame.md` — reused, unchanged.
Round `553-the-parser-knew-all-along.md` — built `holdsPartialFrame`, which this round spends.
Round `547-the-second-revert.md` — whose witness arm found this.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [554]`.
