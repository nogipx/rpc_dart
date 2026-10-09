---
round: 721
verdict: FIXED
packages: [rpc_dart_framework]
lens: RPC-21
bench: P-237 — new
commit: yes
release: changelog
severity: S2
---

# Round 721 — stop waits for start

> **Revised by round 730.** The unbounded wait made `stop()` hang for as long
> as an `onStart` did. `stop()` now asks `start()` to roll back and waits at
> most `shutdownTimeout`.

## Target

`3d6eb73e`, the owner's newest framework change: modules now start before
the server. RPC-21 drives a lifecycle out of its expected order, so here
`stop()` lands while `start()` is still inside a module's `onStart`, which is
a real window when `onStart` connects to a database.

## Hypothesis

`start()` sets `_started = true` before its first await. A `stop()` landing
in that window finds no server, stops the modules, marks the app stopped and
returns. `start()` then goes on to start the server, and every later `stop()`
returns at once on `!_started`.

## Before

Probe: `packages/core/rpc_dart_framework/.dart_tool/probe/r721_stop_during_start.dart`.
A module whose `onStart` takes 300 ms and a server that records its calls.
After both calls settle, `stop()` is called once more, as a retry.

```
  arm                        server starts  stops  running at end  onStart  onStop
  CONTROL stop after start         1          1        false          1       1
  stop during start                1          0        true           1       1
```

The module's `onStop` also ran while its `onStart` was still in progress.

## Mechanism

As hypothesised. Nothing ordered `stop()` after a `start()` in progress.

## Fix

`start()` keeps the work it runs as `_starting`. `stop()` awaits it
(ignoring its error, which `start()` reports and rolls back itself) before
reading `_started`.

## After

```
  stop during start                1          1        false          1       1
```

## Canary

The await removed: `stop_during_start_test` fails with "start() went on to
start a server after stop() returned" (`Expected: false, Actual: <true>`).

## The verdict questions

1. Yes. Only the moment of `stop()` differs.
2. Yes: running true against false, stops 0 against 1.
3. In the server double's own calls.
4. Not zero.
5. Quoted.
6. One mechanism.
7. Not a trade. `stop()` now takes as long as the start it overlaps.
8. None.
A1. n/a — no peer.
A2. Latency: a slow `onStart`, introduced by the probe.
L1. n/a.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check`. rpc_dart_framework
suite: 91.

## Not fixed

The same window was swept in the other five start/stop pairs:

- `RpcWebSocketServer` orders the two through `_stopping`.
- `RpcHttp2Server` claims the bind before its await (`74bb4052`).
- `RpcHttpServer.stop()` during `afterModulesStart`'s bind: the bind lands
  after the stop and the listener stays up until a second `stop()`. Under
  `RpcApp` that hook now completes before `stop()` proceeds, so only direct
  use can reach it.
- `LogCollectorServer.stop()` during `start()`'s bind: a debugging CLI.

Both of the last two are left as they are: low reach, and outside the
framework path this round fixed.

## Links

Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [..., 721]`.
New bench `../probes/P-237-stop-during-start.md`.
