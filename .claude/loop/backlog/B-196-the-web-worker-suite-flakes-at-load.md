---
status: open
round: 508
commit: 5fa2b280
paths: [packages/transport/rpc_dart_isolate/test/web_worker/worker_startup_failure_test.dart, packages/transport/rpc_dart_isolate/test/web_worker/echo_worker_test.dart]
probe: none — observed twice during the gate, not yet instrumented
reason: "bench — a gate that fails intermittently is worse than one that fails: it trains the reader to re-run rather than to look. Seen in rounds 507 and 508, both times at the LOAD stage and never as an assertion"
---

# B-196 — `test:web` flakes at the load stage on the web-worker suite

**Found by the gate, not by a lead**, in rounds 507 and 508 — two rounds in a row,
both times on `worker_startup_failure_test.dart`, both times while *loading* rather
than inside a test:

```
02:08 +1 -1: loading test/web_worker/worker_startup_failure_test.dart [E]
```

No assertion fails. The suite passes alone every time it has been tried, passes
under an ablation of whatever the round was changing, and has passed in the full run
immediately after failing in it.

## Why it matters

**A gate that fails intermittently is worse than one that fails.** Round 507 spent
three full `test:web` runs — several minutes each — establishing that a red gate was
not caused by the change under test. Round 508 hit the same thing and had to do it
again. The cost is paid by every future round, and the failure mode is worse than the
time: the correct response to a red gate is to investigate, and a gate that cries
wolf teaches the opposite.

It also degrades the evidence. Round 507's record has to say "established as a flake
by the ablation run" rather than "green", which is a weaker claim than a round should
have to make about its own gate.

## The shape

Both sightings are at the LOAD stage, which is compile-and-start rather than
execution, and both are in the browser-driven half of the suite. Chrome noise appears
alongside it in the same log:

```
ERROR:ui/display/mac/cv_display_link_mac.mm:188] CVDisplayLinkCreateWithCGDisplay
failed. CVReturn: -6670
```

The script runs these two files with `-p chrome -j 1 --timeout 3x`, i.e. already
serialised and already given triple time, so the obvious knobs are turned. That the
timeout is 3x and it still fails suggests a startup that occasionally does not
complete at all, rather than one that is merely slow.

## Witness a round would build

Run `test:web` in a loop — ten or twenty times — and record how often the load stage
fails, and whether it correlates with the rest of the workspace's suites running
concurrently. Then vary one thing: run the web-worker files FIRST rather than last,
or alone in their own melos step. If the failure rate tracks concurrency, it is
resource contention on the browser launch; if it does not, it is the suite.

A cheaper first arm: capture the full dart test output for a failing load, which the
current grep-based invocation throws away. The `[E]` line is the only evidence so far
and it carries no reason.

## Fix sketch

Unknown until measured. Candidates, in the order the measurement would rank them:
give the browser launch its own melos step so it never competes with twenty other
suites; raise or remove the load timeout specifically; or retry the load once and log
it loudly, which is the worst option and should only be reached for if the first two
refute.

## Owner decision

—
