---
round: 727
verdict: FIXED
packages: [rpc_dart_framework, rpc_dart]
lens: RPC-25
bench: P-240 — new
commit: yes
release: changelog
severity: S2
---

# Round 727 — teardown stops the server first, everywhere

## Target

RPC-25 asks one duty of every copy. Here the duty is the order of teardown.
`RpcApp.stop()` stops the server before the modules, so running handlers can
still reach module resources. Two other teardowns exist: `_rollbackStart`
after a failed start, and `RpcTestApp.dispose()`. Since `3d6eb73e` the
server starts after the modules, so a start failing in `afterModulesStart`
leaves a server already serving when the rollback runs.

## Hypothesis

Both siblings stop modules before the endpoint that serves from them.

## Before

Probe: `packages/core/rpc_dart_framework/.dart_tool/probe/r727_rollback_order.dart`.

```
  CONTROL stop()              [server.start, server.stop, module.onStop]
  rollback of a failed start  [server.start, module.onStop, server.stop]
  RpcTestApp.dispose          a call inside onStop SUCCEEDS (still served)
```

## Mechanism

As hypothesised, in both copies.

## Fix

`_rollbackStart` stops the server first, then the modules, then the
isolates. `RpcTestApp.dispose()` closes both endpoints before stopping the
modules. The framework README and the skill's `framework.md` described the
old order in four places, and now state the new one, plus the stop
behaviour from rounds 721-722.

## After

```
  rollback of a failed start  [server.start, server.stop, module.onStop]
  RpcTestApp.dispose          the call inside onStop fails (endpoint closed)
```

## Canary

Two halves, two canaries, each restoring the old order in place:

- rollback: `a failed start stops the server before the modules` fails with
  `Expected: ['server.stop', 'module.onStop'], Actual: ['module.onStop',
  'server.stop']`.
- dispose: `RpcTestApp.dispose closes the endpoints first` fails with "the
  endpoint still served while modules were stopping" (`Expected: false,
  Actual: <true>`).

## The verdict questions

1. Yes. `stop()` is the control and differs only in being the other copy.
2. Yes: two orders.
3. In the module's own `onStop`, and a real call through the endpoint.
4. n/a — not a count.
5. Quoted, both.
6. Two halves, two canaries.
7. Not a trade.
8. None.
A1. n/a.
A2. n/a.
L1. n/a.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check`, `check:skills`.
rpc_dart_framework suite: 94.

## Not fixed

`RpcTestApp.start` has no rollback at all. A module whose `onStart` throws
leaves the modules started before it, and any spawned isolate, running.
That is a separate defect, left for the next round.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 727]`.
New bench `../probes/P-240-teardown-order.md`.
