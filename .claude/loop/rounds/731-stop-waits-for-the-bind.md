---
round: 731
verdict: FIXED
packages: [rpc_dart_http2, rpc_dart_http, rpc_dart_log]
lens: RPC-21
bench: P-242 — new
commit: yes
release: changelog
---

# Round 731 — stop waits for the bind

## Target

Round 721's "Not fixed", completed. That round left three servers for which
a `stop()` landing during the bind's await leaves a listener: `RpcHttpServer`
(bind in `afterModulesStart`), `LogCollectorServer`, and `RpcHttp2Server`,
found by reading in round 729. `RpcApp` no longer reaches it (round 730), but
each server is public and is driven directly.

## Hypothesis

`stop()` finds nothing bound yet and returns. The bind then lands, and the
server listens with nothing left to stop it.

## Before

Probe: `.dart_tool/probe/r731_stop_during_bind.dart` in each of the three
packages. A free port, `start()` (for http, `afterModulesStart()`) not
awaited, `stop()` at once, then a connect to the port.

```
  server              CONTROL stop after start   stop during bind
  RpcHttp2Server      port accepts: false        isRunning true, port accepts: true
  RpcHttpServer       port accepts: false        isRunning true, port accepts: true
  LogCollectorServer  port accepts: false        port accepts: true (canary arm)
```

## Mechanism

As hypothesised. Each `stop()` read state that is set only after the bind's
await.

## Fix

Each start publishes its bind before the first await, as a future completed
in a `finally`, and `stop()` waits for it before reading any state.
`RpcHttp2Server._bind`, `RpcHttpServer._bind` (the bind and serve moved into
`_bindAndServe`) and `LogCollectorServer._starting`. A bind is local and
bounded, so the wait cannot hang the way round 721's did.

## After

```
  all three           stop during bind: port accepts: false
```

## Canary

The wait disabled in each. `stop() during the bind leaves nothing listening`
fails for h2 and http with `Expected: false, Actual: <true>` (`isRunning`).
The log server's probe arm reads `port accepts: true`.

## The verdict questions

1. Yes: only the moment of `stop()`.
2. Yes: true against false on the port.
3. A real TCP connect to the port.
4. n/a.
5. Quoted.
6. Three copies, three canaries.
7. Not a trade. A `stop()` during a bind now takes as long as the bind.
8. None.
A1. n/a.
A2. Latency: the bind's await.
L1. n/a.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check`. Suites:
rpc_dart_http2 306, rpc_dart_http 232, rpc_dart_log 91.

The first `test:unit` run failed one test in `rpc_dart_isolate`, a package
this round does not reach: `startup_failure_releases_the_isolate_test`,
"still running". That test gives a child `dart run` (compile included)
20 s, with load average 15.6 during the workspace run. Alone it passes in
1 s, a 20x margin. The isolate suite alone passes 102/102. The variable is
the workspace's concurrent suites, not the code. A re-run of the whole
`test:unit` was green.

## Not fixed

`RpcWebSocketServer` binds nothing itself and already orders the two calls
through `_stopping`.

## Links

Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [..., 731]`.
New bench `../probes/P-242-stop-during-the-bind.md`.
