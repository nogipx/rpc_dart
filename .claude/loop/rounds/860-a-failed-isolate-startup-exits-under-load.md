---
round: 860
verdict: CLEAN
packages: [rpc_dart_isolate]
lens: RPC-14
bench: P-327 — new
commit: yes
release: none
---

# Round 860 — a failed isolate startup exits under load

## Target

B-293: round 853's first full gate failed `a spawn that times out leaves
no isolate and no ports behind` with "still running", and the file passed
alone and in the next gate. If the isolate or a port really outlives a
timed-out spawn under load, that is I-5 (resources return) and S1. RPC-14:
a timeout abandons the wait, not the work.

Read first: the startup deadline starts only after `await Isolate.spawn`
returns, so the isolate always exists by the time teardown would kill it.
The test's 20 s clock starts at the child's launch, and `dart run`
compiles before main runs.

## Hypothesis

Under load the child exits as it does alone, only later. Fails if any
child never exits.

## Before

```
P-327, children started at once:
n    exited   total per child     "spawn threw" line -> exit
1    1/1      1.6 s               -
24   24/24    9.2-10.1 s          -
48   48/48    40.7-45.6 s         -
48   48/48    51.0-53.6 s         13-303 ms
control, teardownStartup() removed, n = 2: HUNG >90 s on both
```

## Mechanism

No leak. Under load `dart run` spends tens of seconds compiling and
spawning before the support script's main reaches the failed startup; the
test counted that against its 20 s exit deadline and read a slow start as
an isolate left running.

## After

The test starts its 20 s exit deadline at the child's "spawn threw" line
and gives the start-up before it 150 s of its own, reported separately
("never reached the failed startup").

## Canary

Fixed test with `teardownStartup()` removed from the ready-timeout path:
failed after 21 s with `Expected: 'exited 0' Actual: 'still running'`.
Restored: passes in 1 s.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(isolate +102, rpc_dart +2220 ~1, http2 +358, http +261, websocket +331,
conformance +512 ~150); `format:check` SUCCESS; `license:check` compliant.

## Siblings

—

## Not fixed

The handshake-timeout path was not reached by any run (the worker always
sent its handshake within 500 ms); it has its own teardown.

## Links

Lens `../lenses/RPC-14-timeout-abandons-work.md`. Bench
`../probes/P-327-a-failed-isolate-startup-under-load.md`. Negative
`../checked/C-91-a-failed-isolate-startup-exits-under-load.md`. Lead
`../backlog/B-293-a-failed-isolate-startup-reads-as-still-running-under-the-gate.md`.
