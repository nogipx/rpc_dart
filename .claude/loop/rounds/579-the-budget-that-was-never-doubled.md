---
round: 579
verdict: FIXED
packages: [rpc_dart_isolate]
lens: RPC-15
bench: P-200 — new
budget: probes 1/5, canaries 0/5
commit: yes
release: none
severity: S3
---

# Round 579 — the budget that was never doubled

## Target

`B-157`, the third isolate item in a row, because its headline is an arithmetic claim — "a 30 s default is
really 60 s" — and an arithmetic claim is either true or it is not. Three claims on the lead; this round
answers two and leaves the third, which has no failure to measure.

Lens RPC-15: re-measure the record. Here the record is the audit's, and `C-61` says its `## Why it
matters` lines do not predict outcomes in either direction.

## Hypothesis

Two phases each get the full `startupTimeout`, so a worker that never becomes ready costs twice the
budget.

## Before

```
a worker that stalls before `ready`
    budget  500ms -> failed after  521ms (1.04x)  TimeoutException
    budget 1000ms -> failed after 1002ms (1.00x)  TimeoutException
    budget 2000ms -> failed after 2002ms (1.00x)  TimeoutException
```

**REFUTED. 1.00x, not 2x.** Probe:
`packages/transport/rpc_dart_isolate/.dart_tool/probe/b157_startup_budget.dart`.

Both timeouts are real and sequential — `handshake.future.timeout` and `ready.future.timeout`, one
`startupTimeout` each. What the lead's arithmetic missed is that **nothing a caller controls can make the
first one slow**: the worker's wrapper sends its `SendPort` as its very first act, before a line of user
code runs. So phase 1 costs the spawn itself and phase 2 gets the budget, and the true worst case is
`spawn + startupTimeout` rather than `2 x startupTimeout`.

**The rig was wrong first, and it reported a PASS.** A stall written as
`Future.delayed(...).then(...)` schedules and RETURNS, and the wrapper sends `ready` immediately after
`userEntrypoint(...)` returns — so spawn SUCCEEDED in 28 ms and the arm measured nothing. The stall has to
be synchronous; a busy-wait is what blocks the worker's event loop.

## Mechanism

Claim 3 is the one that holds, and reading settles it. `killIsolate` calls `hostTransport?.close()`
WITHOUT awaiting — `kill` is `void Function()` — so it runs as far as `close()`'s first await,
`_channelSub.cancel()` (`channel_transport.dart:627`), and yields. `teardownConnection()` then kills the
isolate synchronously, and the frame `_channel.close()` would send (`:645`) goes out afterwards, to an
isolate that is already gone. **The comment claimed the opposite order.**

## After

The comment now says what happens, and why it is a trade rather than an accident: making the frame go
first means awaiting the close, which means `kill` returning a `Future` — a public signature change, so
not a round's to make.

The budgets are UNCHANGED, deliberately. See `## Not fixed`.

## Canary

**None, and none is possible: nothing was switched off.** The round's two results are a refutation and a
comment correction.

What stands in for one on the refutation is the rig's own failure: the first version reported
`0.06x / 0.00x` with `thrown.runtimeType == Null`, which is what a measurement looks like when its
subject never happens. The three budgets then reading `1.04 / 1.00 / 1.00` across a 4x range is what makes
the ratio a property rather than one timing.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_isolate +93
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2201 / 2201, REUSE compliant
```

## Not fixed

**The two budgets are left as they are, and that is a judgement.** One deadline across both phases would
make the documented contract exact, but it has **no failing arm**: phase 1 cannot be made slow through
the public API, so nothing distinguishes one budget from two in any test that can be written. Rounds 563
and 564 declined a one-line guard for exactly that reason, and the same bar applies here.

**Claim 3 is fixed as PROSE only.** Whether the close frame SHOULD precede the kill is a design question
whose answer changes `kill`'s signature.

**Claim 2 is untouched**: the worker replies with a SendPort and the host then sends a second port in an
`init` message where one would do. An extra round trip on a path that runs once per isolate, with no
failure to measure — cost, by reading, and nothing here varies it.

**The order in claim 3 was established by READING, not by a witness.** Observing it would need a spy at
the channel layer, and the isolate it concerns is killed before it could report.

## Links

Lead `../backlog/B-157-isolate-startup-budget-and-handshake.md` — claims 1 and 3 answered, claim 2 open,
so the lead stays open.
Bench `../probes/P-200-is-the-startup-budget-doubled.md` — new.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [579]`.
Lesson: none. The rig error is `measurement.md` item 8 — "zero is suspicious: check whether the mechanism
could emit anything at all" — and `0.00x` was exactly that.
