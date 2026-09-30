---
status: open
round: 543
commit: b566bcb8
paths: [pubspec.yaml, packages/transport/rpc_dart_isolate/test/web_worker/worker_startup_failure_test.dart, packages/transport/rpc_dart_isolate/test/web_worker/echo_worker_test.dart]
probe: none
reason: "the only red left in test:web, and it moves between runs: the same file passed alone in 6 s and later failed alone in 95 s, with the 15-minute load average climbing from 7.5 to 20.5 across the attempts. Nothing so far separates the harness from the load"
---

# B-215 — `rpc_dart_isolate`'s Chrome suites fail differently every run

Round 543 fixed the compression defect that had kept `test:web` red since round 513, and
`set -e` then stopped aborting early — which exposed this, the next red, for the first time.

## What was observed, in order

```
  both files, one invocation      the SECOND fails to load
  echo_worker alone               passes, 34 s
  worker_startup_failure alone    passes, 6 s
  both, one invocation, again     the second fails to load
  --- split into two invocations (round 543) ---
  test:web                        worker_startup_failure: 2 of 4 fail
  worker_startup_failure alone    FAILS to load, 95 s
```

The two that fail under `test:web` are the two needing a HEALTHY worker ("a worker that dies
after startup is noticed", "GUARD: a healthy worker is unaffected"); the two asserting that a
BROKEN spawn is reported pass. The error:

```
RpcStatusException(14): RpcIsolateTransport.spawn: worker ".../echo_worker.dart.js?rpcPolicy=..."
failed during initialization: the worker script failed to load or threw during startup
```

`echo_worker.dart.js` exists and is current — `test:web` compiles it first, deliberately.

## Why this is not yet a diagnosis

The last line above is the problem: the same file passed ALONE in 6 s and later failed ALONE in
95 s. So the invocation shape is not the variable. Across the attempts the 15-minute load
average went from 7.5 to 20.5, driven by the runs themselves, which is precisely the condition
`config.md` names for "batches of failures that look like real flakes".

Round 543 split the two files into separate invocations on the strength of the script's own
comment — `-j 1` serialises TESTS, not BROWSERS, so one `dart test` starts the second Chrome
while the first is shutting down. That mechanism is real and the split removes one cause. It is
NOT shown to make the target deterministic, and this lead exists because that distinction was
not measured.

## Witness a round would build

**On a quiet machine** — the first thing to establish, since every reading so far is
contaminated. `uptime` under 3 before starting, and stated in the record.

Then N runs of each shape, counting failures rather than describing one: both-in-one-invocation
against split, and each file alone. A frequency, not an anecdote. If the split shows no
difference at low load, revert it — it is then complexity bought with nothing.

Worth asking separately whether a worker that fails to LOAD can be told from one the browser
refused to start under pressure. The transport reports both as "failed to load or threw during
startup", which is the same string for a code defect and for an exhausted machine.

## Owner decision

—
