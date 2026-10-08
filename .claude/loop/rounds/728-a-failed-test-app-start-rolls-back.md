---
round: 728
verdict: FIXED
packages: [rpc_dart_framework]
lens: RPC-25
bench: P-241 — new
commit: yes
release: changelog
---

# Round 728 — a failed test-app start rolls back

## Target

Round 727's "Not fixed". `RpcTestApp.start` has no rollback at all, while
its sibling `RpcApp.start` does. In a test suite, a module whose `onStart`
throws leaves the modules started before it, and every spawned isolate,
running for the rest of the run.

## Hypothesis

A started module gets no `onStop` when a later module's `onStart` throws.

## Before

Probe: `packages/core/rpc_dart_framework/.dart_tool/probe/r728_test_app_start_rollback.dart`.
Module A, then module B, whose `onStart` throws.

```
  CONTROL RpcApp      A.onStop after B failed: 1
  RpcTestApp.start    A.onStop after B failed: 0
```

## Mechanism

As hypothesised. Nothing in `RpcTestApp.start` caught the failure.

## Fix

The spawn, start and register steps run inside one `try`. On failure,
everything is undone in round 727's order before the error is rethrown: both
endpoints close, the started modules stop in reverse, the spawned isolates
terminate. The README says so.

## After

```
  RpcTestApp.start    A.onStop after B failed: 1
```

## Canary

The module rollback removed: `a failed RpcTestApp.start stops what it
started` fails with "a module started before the failure was left running"
(`Expected: ['module.onStop'], Actual: []`).

## The verdict questions

1. Yes. `RpcApp` is the control and differs only in being the other copy.
2. Yes: 1 against 0.
3. In the module's own `onStop`.
4. Not zero: the control emits 1.
5. Quoted.
6. One mechanism. The isolate half has no witness: no test module spawns an
   isolate here.
7. Not a trade.
8. None.
A1. n/a.
A2. n/a.
L1. n/a.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check`. rpc_dart_framework
suite: 95.

## Not fixed

The isolate-termination half is verified by reading only.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 728]`.
New bench `../probes/P-241-a-failed-test-app-start.md`.
