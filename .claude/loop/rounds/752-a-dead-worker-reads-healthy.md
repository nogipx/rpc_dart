---
round: 752
verdict: FIXED
packages: [rpc_dart_framework]
lens: RPC-21
bench: P-257 — new
commit: yes
release: changelog
---

# Round 752 — a dead worker reads healthy

## Target

`next` listed four open leads; `stale` marks B-267, B-268 and B-269 STALE and
B-270 fresh. None of the four was taken, and none is ruled out: this round
did not re-measure them, so they stay open as filed.

Taken instead: `rpc_dart_framework`'s `RpcIsolateModule`, a lifecycle surface
`find --path` shows no round has measured. Read with dart-runner:
`RpcApp.health()` and `RpcTestApp.health()` take each module's
`checkHealth()`; `RpcModule.checkHealth()` returns null; `RpcIsolateModule`
does not override it. Round 705 (web transport death) and P-91 (what a caller
is told) are about the transport, not about what the app reports.

Scope, counted before the fix: in `rpc_dart_framework/lib`, the only module
that holds a live resource of its own is `RpcIsolateModule` (24
implementations of `RpcModule`; the other 22 are in `test/`, plus the
abstract `RpcServerModule`). One site.

## Hypothesis

When the worker isolate exits after startup, calls to its contracts fail from
then on, and `health()` still reads healthy.

## Before

```
                     control   die
  echo before        ok x      ok x
  health before      healthy   healthy
  die call           -         status 14
  worker transport   open      closed
  echo after #1..#3  ok x      status 14, all three
  health after       healthy   healthy   modules={}
```

Probe: `packages/core/rpc_dart_framework/.dart_tool/probe/r752_dead_worker.dart`

## Mechanism

The worker is not restarted, so its closed transport is permanent. The one
signal a supervisor reads, `checkHealth()`, was the inherited null.

## Fix

`RpcIsolateModule.checkHealth()` returns `unhealthy` once the worker
transport is closed, and null otherwise, so a healthy app's report is
unchanged. `appLevelOf` already turns an unhealthy module into an unhealthy
app. The framework README and the shipped skill's `framework.md` say a dead
worker is not restarted and what health then reports.

## After

```
                     control   die
  worker transport   open      closed
  echo after #1..#3  ok x      status 14
  health after       healthy   unhealthy  modules={Worker: unhealthy}
```

## Canary

`WITNESS a worker that died makes the app unhealthy`, with the condition
forced to null, failed with:

```
  Expected: RpcAppHealthLevel:<RpcAppHealthLevel.unhealthy>
    Actual: RpcAppHealthLevel:<RpcAppHealthLevel.healthy>
  every call to the worker now fails, and health() said healthy
```

The GUARD (a live worker leaves the app healthy, no module entry) passed in
both runs.

## The verdict questions

1. Yes: the arms differ only in the `Die` call.
2. Yes: `health after` reads healthy for both before the fix, and the worker
   transport and the calls show the die arm reached the defect.
3. In `RpcTestApp.health()`, the library's own report.
4. n/a, the result is not a zero.
5. Quoted above.
6. One half.
7. From the table.
8. B-267, B-268, B-269 and B-270 were not dismissed: not re-measured, left
   open. Round 705 and P-91 were not taken as covering this by their text:
   the `die` arm's `health after  healthy` on today's code is what shows the
   gap is open.
9. None.
A1. n/a: no attacker; the failure is the worker's own exit.
A2. Neither: the gap is an event, the worker exiting, and the bench causes it.
L1. n/a: no refusal is used as evidence.

## Gate

`melos run analyze`, `test:unit` (rpc_dart 2110, framework included),
`format:check`, `license:check`: green. `check:skills` clean.

## Not fixed

Restarting the worker. It is a new capability with policy choices (how often,
what happens to calls in flight), so it is the owner's, by the precedent of
B-01. Health now makes the outage visible, which is what lets a supervisor
restart the process.

## Links

Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [..., 752]`.
New bench `../probes/P-257-a-dead-worker-and-what-health-says.md`.
