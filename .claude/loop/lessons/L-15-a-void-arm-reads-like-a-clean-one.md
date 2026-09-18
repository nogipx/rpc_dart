---
round: 384
class: bench
cost: twelve rounds. C-41's `deadline: 0` was recorded in 372 and stood through 383; it measured the teardown of a call the server had never heard of, because before round 373 a bidi caller holding its request stream open sent no initial metadata at all. Re-running the unchanged probe reads 5 / 20 / 27. The ablation could not protect it, and `loop.py stale` could not flag it even though 373 touched a file inside the bench's own `paths:`
paths: [packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/caller.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
commit: 69d24a76
status: active
---

# L-15 — a bench arm whose subject never reaches the code reads exactly like a clean one

## The rule

A zero means "the mechanism ran and left nothing" **only if the scenario
actually reached the mechanism**. An arm whose subject never arrives produces
the same zero as an arm that arrives and is handled correctly, and nothing in
the number distinguishes them. So for every arm, ask a second question beside
*could the instrument report non-zero?* — namely **did the thing under test
happen at all?** — and record an observable that says so.

`measurement.md` item 8 already says a zero is suspicious and to check the
mechanism could emit anything. This is the case that slips past it: the
instrument was fine and the mechanism was fine. The SCENARIO was void.

## The price

C-41 (round 372) recorded seven ways of ending a bidi call, every cell zero at
three scales, resting on an ablation that made the counters climb 5 / 25 / 85.
The ablation was real and the negative was believed.

Its `deadline` arm drove a caller holding its request stream **open** — and
before round 373 a bidi caller that never sent and never half-closed **never
sent initial metadata at all**, so the server had no such call. The arm measured
the teardown of a call that did not exist. Round 373 landed the fix that made
those calls arrive, and nobody re-ran P-63.

**The row stood false from round 372 to round 384 — twelve rounds** — and it is
the ending most likely to be leaned on, since a deadline is the commonest way a
real call ends. Re-running the unchanged probe reads 5 / 20 / 27.

The ablation did not protect against it, and could not: it removed the
responder's CLEANUP, which the six live arms exercise, so it proved the
instrument could see a leak without saying anything about whether the seventh
arm's call ever opened.

## How to apply it

Cheapest form, and it would have caught this one: **assert the arm's own setup
before measuring its outcome.** P-64 already does exactly this under the name
HOP CHECK — it samples the server's `openStreams` / `activeResponders` /
`metadataStreams` WHILE the call is in flight, which is how round 373 found the
second hop instead of assuming it. P-63 had no such sample, so a call that never
reached the server was indistinguishable from one that did.

The second form is a rule about re-measurement: **when a round changes WHETHER a
call reaches the peer, every bench arm that depends on it is stale, whatever its
own paths say.** `loop.py stale` computes from path churn and cannot see this —
round 373 touched `bidirectional/caller.dart`, which is inside P-63's `paths:`,
and P-63 was still not re-run.

## What a reader gives up by having this as the fifteenth lesson

Attention, which is the lesson layer's binding constraint, and this one is close
enough to `measurement.md` item 8 to look like a restatement on a first read.
It is filed anyway because the twelve-round price was paid for the DIFFERENCE
between them: item 8 asks whether the instrument can speak, and this asks
whether there was anything to speak about. A reader who takes only item 8 from
both has lost the case that actually happened.
