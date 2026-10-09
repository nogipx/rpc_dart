---
round: 542
verdict: FIXED
packages: [rpc_dart]
lens: RPC-08
bench: P-140 — reused
budget: probes 1/5, canaries 2/5
commit: yes
release: breaking
---

# Round 542 — the ceiling that was a fallback

## Target

B-111's remaining half, an owner decision and therefore the round's first target: **`global`
must be a CEILING** — checked always, in addition to whichever specific counter matched. The
streaming half of the same lead was fixed in round 502.

Lens RPC-08: one name, one promise. Here the promise is in the word — `global` — and the code
made it the last entry in a first-match chain.

## Hypothesis

`_resolveCounter` returns `perMethod ?? perService ?? perKeyFallback ?? global` and stops, so
a call with any more specific limit is not subject to the global one at all.

## Before

```
CONTROL unary                      admitted 5 / 100  (must be 5)
CONTROL bidi, 1 request message    admitted 5 / 100  (must be 5)
bidi, ZERO request messages        admitted 5 / 100
client-stream, ZERO messages       admitted 5 / 100
CONTROL 1 call, 10 messages, max 5 delivered 5  (must be 5, not 10)
unary, global 5 + perMethod 1000   admitted 100 / 100     <- the finding
unary, global 5 + perMethod 2       admitted 2 / 100  (must be 2)
global 5/s + perMethod 10/h        admitted 10, then 0 after the global window rolled
```

Bench `../probes/P-140-what-the-rate-limiter-admits.md`, reused with three arms added; its
five original arms are repeated first as the control and read exactly as round 502 recorded
them, which is what says the bench still works at today's sha.

**`global: 5` admits 100 of 100** when a looser `perMethod` exists. Round 502's number,
reproduced.

The last row is the new arm and it says the same thing from the other side: with `global:
5/s` and `perMethod: 10/h`, ten calls went through in the first second — the per-method
counter was the only one acting — and then none at all, because the per-method budget was
spent and the global window rolling over could not help.

## Mechanism

**Two halves, and the second exists only because of the first.**

`_resolveCounter` became `_resolveSpecific`, which no longer falls through to
`_globalCounter`; a new `_tryAcquireAll` takes a slot from the specific counter AND from
global, and admits only if both do. So the tighter of the two always binds, in either
direction, and the word `global` means what it says.

**A refused call must cost nothing anywhere.** Two counters cannot be consulted
simultaneously, so the specific one is charged before global has answered — and if global
then refuses, that token is spent on a call that never ran. Under sustained overload the
specific counter drains on refusals alone, which tightens a limit that was never reached:
the failure mode is the opposite of the defect. `_RateLimitCounter.refund()` gives the slot
back, exactly inverting `tryAcquire` for both algorithms (the sliding window decrements the
CURRENT bucket, the only one it increments; the token bucket adds one token back, clamped to
its burst so a refund cannot overfill it).

The per-message path goes through the same `_tryAcquireAll`, so a streaming call is metered
against the ceiling too. Its up-front "does any limit apply" probe is now
`_anyLimitApplies`, since `_resolveSpecific` returning null no longer means "unlimited".

**The eviction case still works**, which B-111's decision said to read first: the counter is
re-resolved on every message so a live stream rebinds to the canonical map entry after
`_cleanup` evicted and a concurrent stream recreated it. `_tryAcquireAll` re-resolves per
call, exactly as before.

**Breadth: one site.** `grep` for `perMethod` across every package's `lib/` returns this file
alone, so no sibling implements the same resolution.

Also removed here: `_statusResourceExhausted = 8`, a second home for
`RpcStatus.resourceExhausted`, named in this lead and used twice in the same file.

## After

```
unary, global 5 + perMethod 1000   admitted 5 / 100
unary, global 5 + perMethod 2       admitted 2 / 100  (must be 2)
global 5/s + perMethod 10/h        admitted 5, then 5 after the global window rolled
```

Every control row unchanged. The middle row is the guard that says the fix did not overshoot
into "global decides", and the last one reads `5, then 5` rather than `5, then 0`, which is
the refund.

## Canary

Two, one per half.

```
1. global goes back to being a fallback (skipped whenever a specific counter matched)

   WITNESS a looser perMethod does not lift the global ceiling
     Expected: <5>
       Actual: <100>
   and two more: the refund arm read 10 instead of 5, and the streaming arm 10
   instead of 5. The two GUARD tests stayed green.

2. the refund removed (return without giving the specific slot back)

   WITNESS a call refused by global does not spend the per-method budget
     Expected: <5>
       Actual: <0>
   the per-method budget of 10 spent on the 95 calls global refused. The other
   FOUR tests stayed green, which is what isolates this half from the first.
```

Canary 2 is the one worth having. Without it the fix passes every arm that measures
admission, and the damage is invisible until a limit that is configured generously starts
refusing — at which point it looks like the ceiling working.

## Gate

```
melos run analyze                No issues found!            21 packages + wasm
melos run test:unit --no-select  All tests passed            14 packages
melos run format:check           0 changed                   21 packages + wasm
melos run license:check          2103 / 2103, REUSE compliant
```

`format:check` failed once on the two changed files and was re-run green.

`test:unit` FAILED on its first run, in `rpc_dart_http`, with exit code 1 — **and the failing
test is not known**, because the invocation printed only its tail and the reporter's failure
lines were gone by the time it was re-run. The package passed alone immediately afterwards
(174 tests) and two subsequent full runs passed, at a 15-minute load average of 10.33, which
is the condition `config.md` names for load-induced batches of failures. That is recorded as
UNEXPLAINED, not as a flake: the rule the config states is to name the failure first, and this
round could not. The process error is mine — a gate step that fails must be captured in the
same invocation that fails it.

In the changed package: `test/resilience` 158 tests green.

## Not fixed

**`_resolveSpecific` still rebuilds the method-key string and re-runs `_keyExtractor` on
every message**, and now `_tryAcquireAll` is on that path too. The re-resolution is deliberate
and commented — it rebinds after an eviction — so the cost is real and the obvious fix is
not. Cost, not correctness; filed as B-213 with the eviction case named as the thing to
measure first.

**Nothing warns about a self-contradictory configuration.** A `perMethod` looser than `global`
is now harmless rather than a hole, but it is still a configuration whose author believed
something false. B-111's option 2 (warn at construction) was not taken and not needed after
this; named in B-213 as the smaller remaining question.

## Links

Lead `../backlog/B-111-the-rate-limiter-global-is-not-global.md` — closed by this
round; its owner decision is what the fix carries out.
Lead `../backlog/B-213-the-rate-limiter-resolves-its-counters-per-message.md` — new.
Bench `../probes/P-140-what-the-rate-limiter-admits.md` — reused; five original arms repeated
as the control, three added.
Round `502-the-shape-that-was-never-admitted.md` — the streaming half of the same lead.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [542]`.
