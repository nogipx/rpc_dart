---
round: 214
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-05
bench: P-06 — new
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks, so the `loop.py review` prompt was answered in full against the record, the bench and the ablation; approved 10 of 10
commit: no
---

# Round 214 — handler slots come back on every teardown path

## Target

RPC-05, never applied, and the first round in nine to leave flow control. Rounds
206-213 all lived in credit accounting; `next` still offers RPC-01 because its
status is `confirmed` rather than `swept here`, and SKILL.md ranks a
NEVER-APPLIED lens above the rank.

RPC-05 asks, for every `RpcSecurityPolicy` field, where it is charged and where
released. `maxConcurrentHandlers` is the field with the most lifecycle: charged
at DISPATCH, released at the LATER of stream teardown and handler completion,
through two paths that have to agree.

## Hypothesis

A slot charged and never released is capacity the server never gets back, and it
is silent — every call still reports success. Some teardown path reaches neither
`_withHandlerSlot`'s `finally` nor `_cleanupStream`.

## Before

```
ceiling 3, six calls churned through a teardown path, then a burst of twelve:

                      peak concurrent handlers
  normal (control)              3
  throw                         3
  cancel                        3
  deadline                      3
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/handler_slots_return.dart`
(P-06).

The `deadline` row is the one worth naming: the handler ignores its cancellation
token, so the stream is reclaimed while the work runs on, and the slot is
deliberately held past the stream's death. It still comes back.

## Mechanism

The hypothesis does not hold. `_withHandlerSlot` and `_withHandlerSlotStream`
both release in a `finally`, the second as a generator so cancellation runs it
too; `_cleanupStream` releases from the other end; and `_releaseHandlerSlot` is
guarded by `_respHandlerLive` so whichever arrives second is the one that frees
it. Six churned calls against a ceiling of three would have exhausted it twice
over on a single leak per call.

## After

n/a — nothing changed. `git diff` is empty; the ablation was reverted in place.

## Canary

n/a — no fix. The ABLATION is what carries the claim: with `_releaseHandlerSlot`
made a no-op, all four modes read peak 0 — total capacity loss — against 3 with
it in place. That is what makes this a bench rather than a probe, and what makes
CLEAN mean something here rather than being hope.

## Gate

No code changed, so the gate is the one HEAD passed at round 212.

## Not fixed

**The sweep is not complete, and the lens status says so.** RPC-05's detector is
"for every `RpcSecurityPolicy` field", and there are sixteen. Most are pure
predicates — `maxMessageLengthBytes`, `maxHeaders`, `maxMetadataBytes`,
`maxHeaderNameBytes`, `maxHeaderValueBytes`, `maxMethodPathLength`,
`maxMessagesPerChunk`, `closeOnProtocolError` — checked at a point, holding
nothing, so they have no charge/release pair to get wrong. The ones that DO hold
state:

- `maxConcurrentHandlers` — this round, clean, with a validated bench.
- the four flow-control fields — rounds 206-213, exhaustively.
- `maxActiveStreams` — stream ids and the fc maps; round 212 fixed a leak here
  and round 212's test pins every counter returning to zero.
- `halfOpenStreamTimeout` — round 205 measured 20 parked streams reclaimed to 0.
- `maxBufferedBytes` / the pre-method byte budget — **not swept.**

That last one is the gap, and it is the highest-severity one left: the budget's
own comment records what it was built to stop — 250.7 MiB pushed at a stream id
never opened with metadata cost a server 495.2 MiB of RSS, unauthenticated.
Filed as B-16 with the bench design.

## Links

Bench `../probes/P-06-handler-slots-return.md` — new, validated by an ablation.
Lead `../backlog/B-16-pre-method-byte-budget-release.md` — new, the rest of this
detector.
Lens `../lenses/RPC-05-concurrency-limit-charge-point.md` — `applied: [214]`,
with the swept and un-swept fields written into it.
