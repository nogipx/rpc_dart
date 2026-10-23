---
status: open
round: (not re-measured)
commit: 99126bfa
paths: [packages/transport/rpc_dart_isolate/test/audit/startup_failure_releases_the_isolate_test.dart]
probe: P-327
reason: bench — intermittent: red once in round 897's full gate ("never reached the failed startup"), green alone 3/3 and in the next full gate
rank: 9
---

# B-311 — the failed startup witness never reached its startup

Round 897's first `test:unit:quiet` failed one test outside the round's
package: rpc_dart_isolate's "a spawn that times out leaves no isolate and no
ports behind", `Expected: 'exited 0' Actual: 'never reached the failed
startup'`. That text means the child script did not print `spawn threw`
within 150 s of its launch -- not the "still running" that B-293 (closed in
round 860) was about, which moved the exit deadline to start at that line.

The round touched only `rpc_dart_socket`. Alone the test passed 3/3 in about
a second; the whole `test:unit:quiet` rerun was green.

Unknown: whether the child was still compiling at 150 s under the gate's
load, or ran and never threw.

## Next step

Record the child's stdout and stderr in the failure message, so the next red
says which of the two it was, and run the full gate until it recurs.

## Owner decision

—
