---
round: 656
verdict: FIXED
packages: [rpc_dart]
lens: RPC-21
bench: none — the witness test is the measurement; reviewer probe res2_force_reconnect_after_disconnect.dart
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 656 — forceReconnect after disconnect

## Target

The resilience review: `RpcClientConnection.forceReconnect` while the loop
`disconnect()` stopped is still asleep.

## Hypothesis

`forceReconnect()` resumes "even if disconnect() was previously called", as
documented.

## Before

```
first connect fails, loop sleeps 300 ms; disconnect; forceReconnect
forceReconnect at +400 ms (loop exited)    factoryCalls=2  Online
forceReconnect at +10 ms (loop asleep)     factoryCalls=1  Idle, for good
```

## Control

The +400 ms row.

## Mechanism

RPC-21, driven during the window. The "a loop is already running" early return
came before `_isStopped = false`. The loop was a stopped one: it woke, saw the
stop and exited, and nothing else was coming. `connect()` resets the flag
first and resumes that loop; `forceReconnect()` did not.

## After

A running loop that is stopped is resumed (flag cleared, attempts reset); a
loop that is not stopped is left alone, as before. Both rows read Online after
two factory calls.

## Canary

The resume disabled: `RpcClientIdle`.

## Gate

Recorded in round 657.

## Not fixed

The backoff sleep cannot be cancelled: after `disconnect()` or `dispose()` its
timer keeps the isolate alive for up to `maxDelay`. A resource nit, not a
wrong answer.

## Links

Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [..., 656]`.
Test `packages/core/rpc_dart/test/resilience/force_reconnect_resumes_a_stopped_loop_test.dart`.
