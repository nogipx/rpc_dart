---
round: 454
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-106 — new
commit: yes
severity: S2
---

# Round 454 — the order the sibling wrote down

## Target

B-83, next of the cheap decided leads. Premise checked against the tree first and
it holds: the drain refusal still tests before the closed-stream guard, the
ceiling refusal still sits after it, and only the ceiling explains itself.

## Hypothesis

The ceiling's comment states the rule — *"Checked after the closed-stream guard,
so a late frame for a torn-down id cannot burn a slot"* — and the drain branch has
the opposite order with nothing explaining it. So a TRAILING frame for an
already-closed stream, arriving while draining, gets the drain refusal instead of
being ignored.

## Before

```
draining, late frame on a closed id   status=14 "Server is shutting down"
NOT draining, same frame              NONE (ignored)
GUARD draining, NEW stream            status=14, status=14
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/drain_refusal_ordering.dart`

The two arms differ only in the drain flag and the outcome flips, so the ordering
is what produced the answer.

## Mechanism

It is the bug the other comment exists to prevent, not an undocumented
specialisation. The peer completed that call and was told OK. A late
metadata-only frame on the same id — which the closed-stream guard exists to
ignore — reached the drain check first and was answered UNAVAILABLE: a SECOND
terminal status on one stream.

## After

The drain check now sits with the ceiling refusal, after the guard. Both arms read
`NONE (ignored)`.

## Canary

The pre-change ordering restored in place:

    Expected: empty
      Actual: ['14']
    the peer was already told this stream was OK; answering it UNAVAILABLE puts
    a second terminal status on one stream

`+2 -1`, with the control and the GUARD green.

**The guard is load-bearing here and not decoration.** Moving a refusal later is
exactly the change that can disable it, so the third test opens a genuinely NEW
stream while draining and requires UNAVAILABLE. A drain that stops refusing new
calls is not a drain, and nothing else in the suite would have caught that.

## Gate

`melos run analyze` SUCCESS. `test:unit` SUCCESS over 14 packages; `rpc_dart`
1672 passed 1 skipped, up three. `format:check` and `license:check` SUCCESS.

## Not fixed

**The guard arm exposed a SECOND defect of the same damage class, and it is
pre-existing.** A new call opened with metadata AND payload while draining is
refused TWICE — `status=14, status=14` — because the drain check fires per frame
and the refusal does not mark the id so the next frame is caught. Two terminal
statuses on one stream, which is what this round just fixed for the closed-stream
case.

Measured on both sides of the change: the canary run shows the same double answer
with the old ordering, so this round neither caused nor fixed it. Filed as
**B-90** rather than folded in, because it is a different mechanism — the refusal
not closing the stream it refuses — and one defect per round.

## Links

- RPC-25 — two refusals, one shared guard, and only one of them knew where it
  belonged; U-01, a comment justifying deliberateness is a lead and here the
  comment was on the RIGHT one
- P-106 — what a late frame on a closed stream is told
- B-83 — closed by this round
- B-90 — new, the double refusal the guard arm exposed
- B-59 and round 414's `markDraining` work — read first, as the lead asked
