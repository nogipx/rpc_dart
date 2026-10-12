---
status: open
round: 853
commit: e01302e8
paths: [packages/transport/rpc_dart_isolate/test/audit/startup_failure_releases_the_isolate_test.dart]
probe: none — the full gate, `melos run test:unit --no-select`
reason: bench — intermittent: failed once in the full gate, passed alone and in the next full run
rank: 7
---

# B-293 — a failed isolate startup reads as still running under the gate

Round 853's first `melos run test:unit --no-select` failed one test:
`a spawn that times out leaves no isolate and no ports behind`, with
`Expected: 'exited 0' Actual: 'still running'`. The same file passed alone
right after, and the whole gate passed on the next run. The round touched
only the unary caller, which this test does not use.

The test runs a child process that must exit once a timed-out spawn is torn
down, and reads "still running" when it has not exited within its wait.
Unknown whether the isolate or a port really outlives the timeout under
load, or the child is only slow to exit while three other packages test in
parallel.

## Next step

Run the file under load (the gate's concurrency, or a CPU hog beside it)
until it fails, and print what the child still holds when it does.

## Owner decision

—
