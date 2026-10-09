---
round: 730
verdict: FIXED
packages: [rpc_dart_framework, rpc_dart]
lens: RPC-15
bench: P-237 — reused
commit: yes
release: changelog
severity: S1
---

# Round 730 — stop does not outwait a hung start

## Target

My own round 721, re-measured on the failure mode it created. After round
729, every fix this session is suspect until its other side is measured. 721
made `stop()` await the `start()` in progress. An `onStart` that never
completes (a database that never answers) is ordinary, and before 721 a
`stop()` returned at once.

## Hypothesis

`stop()` now hangs as long as `onStart` does.

## Before

P-237 (`r721_stop_during_start.dart`), new arm: a module whose `onStart`
never completes, `shutdownTimeout: 1 s`, `stop()` 50 ms into `start()`.

```
  stop during a hung onStart     stop() HUNG after 5004 ms (probe cutoff)
```

## Mechanism

As hypothesised. 721's unbounded `await _starting`.

## Fix

`stop()` sets `_stopRequested` and waits for the start at most
`shutdownTimeout`. `start()` checks the flag before each module's `onStart`
and around starting the server, and rolls back through the ordinary path
when the flag is set. It throws a private `_StoppedDuringStart`, caught
inside `_start`, so the interrupted `start()` completes WITHOUT an error.
That error would otherwise land in a future the caller has stopped
listening to, an unhandled error (RPC-13), which the probe's first version
showed. If the wait times out, `stop()` tears down what exists. A later
resume of the hung start then finds `_tornDown` and does not roll back a
second time. README and skill updated.

## After

```
  CONTROL stop after start      starts 1, stops 1, running false
  stop during start             starts 0 (never started), onStart 1, onStop 1
  two concurrent stops          starts 1, stops 1
  stop during a hung onStart    stop() returned after 1004 ms; starts 0
```

## Canary

The bound removed (`await starting`): `stop() returns while an onStart never
completes` fails with "stop() waited on a hung onStart" (`Expected: true,
Actual: <false>`).

## The verdict questions

1. Yes: the only variable is whether `onStart` completes.
2. Yes: HUNG against returned in 1004 ms.
3. On `stop()`'s own future.
4. n/a.
5. Quoted.
6. One mechanism. The `_tornDown` guard has no witness of its own.
7. A behaviour change: a `start()` interrupted by `stop()` now never starts
   the server, where 721 started it and stopped it again.
8. None new. This is L-20's discipline, "measure the other side of your own
   fix", applied before the owner had to.
A1. n/a.
A2. Latency: a hung `onStart`.
L1. n/a.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check`, `check:skills`.
rpc_dart_framework suite: 96.

## Not fixed

A module whose `onStart` is still hung when `stop()` times out gets `onStop`
while its `onStart` runs. There is nothing better to do with a hung
`onStart`.

## Links

Round `721-stop-waits-for-start.md` is the fix this re-measures. Lens
`../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 730]`.
Bench `../probes/P-237-stop-during-start.md` — new arm.
