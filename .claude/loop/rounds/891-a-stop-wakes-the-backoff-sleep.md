---
round: 891
verdict: FIXED
packages: [rpc_dart]
lens: RPC-21
bench: P-343 — new
commit: yes
severity: S2 — "a bounded leak"
release: changelog
---

# Round 891 — a stop wakes the backoff sleep

## Target

Round 890's own code, driven again (RPC-21): it made a stop end the attempt in
flight, but the connect loop also waits in its backoff with
`Future.delayed`, which nothing stopped. Read while writing round 890, not
from a lead. The owner chose to fix it although it is S2, below the loop's
usual bar.

## Hypothesis

A pending `Future.delayed` timer keeps the isolate alive, so `dispose()`
during a backoff leaves the process running for the rest of the delay -- up
to `maxDelay`, 60 s by default. And `disconnect()` there leaves the loop
asleep, so a `connect()` right after it finds the guard held and waits the
sleep out. Fails if the process exits within a few ms of dispose().

## Before

P-343 (`r891_backoff/probe.dart` via `run.py`), 5 s backoff, no jitter:

```
control (dispose once Online)      exit 12-14 ms after dispose()
arm (dispose mid-backoff)          exit 4905, 4908 ms after dispose()
```

## Mechanism

RPC-21: the stop path covered the attempt (round 890) but not the sleep
between attempts, a second await in the same loop with its own timer.

## After

The sleep is a `Timer` with a wake hook; `dispose()` and `disconnect()` call
it, which cancels the timer and resumes the loop, whose existing
`if (_isStopped) break` ends it. P-343 after: arm 11-13 ms.

`_awaitNextAttempt`'s 5 s wait was checked for the same thing: `dispose()`
closes the state stream, `firstWhere` fails, and `Future.timeout` cancels its
timer. Clean by reading.

## Canary

- `disconnect()` without the wake: WITNESS "connect after a disconnect
  mid-backoff does not wait it out" (`a_stop_wakes_the_backoff_sleep_test.dart`)
  red, "Expected: true Actual: <false> the stopped loop slept out its 5 s
  backoff before connect() could start a new one".
- `dispose()` without the wake: P-343 arm back to 4921 ms. A test in the runner
  cannot see process exit, so the bench is this half's canary.
- GUARD "without a stop the backoff is still waited out": green on both sides.

Restored: witnesses green, P-343 arm 13 ms.

## Gate

`melos run analyze`, `test:unit:quiet --no-select`, `format:check`,
`license:check`, `api:check`: green. The two witness files under `-p node`:
`+6`. No public API change.

## Siblings

`client_connection.dart` belongs to no sibling group in the config; the
reconnect loop has one implementation.

## Not fixed

—

## Links

Round 890, RPC-21, RPC-16, I-5.
