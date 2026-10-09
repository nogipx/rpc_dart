---
round: 722
verdict: FIXED
packages: [rpc_dart_framework]
lens: RPC-21
bench: P-237 — reused
commit: yes
release: changelog
severity: S2
---

# Round 722 — concurrent stops share one

## Target

Round 721's lifecycle, driven twice at once: two `RpcApp.stop()` calls in
flight, as a signal handler and an explicit call can produce. The websocket
server already orders the same case through `_stopping`. That sibling is
the model.

## Hypothesis

`stop()` reads `_started` before its first await and clears it only at the
end. Both calls pass the guard, and both stop the server and every module.
With a drain budget, the second call runs `onStop` while the first is still
draining handlers that use those modules.

## Before

P-237 (`r721_stop_during_start.dart`), with a new arm calling
`Future.wait([app.stop(), app.stop()])` after a completed start:

```
  arm                     server stops  module onStop
  CONTROL one stop             1              1
  two concurrent stops         2              2
```

## Mechanism

As hypothesised.

## Fix

`stop()` returns one shared `_stopping` future and clears it on completion,
as `RpcWebSocketServer.stop()` does. The body moved to `_stop()`.

## After

```
  two concurrent stops         1              1
```

## Canary

The sharing removed: `two concurrent stop() calls stop each module once`
fails with "a second stop ran onStop again" (`Expected: <1>, Actual: <2>`).

## The verdict questions

1. Yes. Only the number of concurrent calls differs.
2. Yes: 2 against 1.
3. In the module's own `onStop` count.
4. Not zero.
5. Quoted.
6. One mechanism.
7. Not a trade.
8. None.
A1. n/a.
A2. n/a: ordering, not latency or volume.
L1. n/a.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check`. rpc_dart_framework
suite: 92.

## Not fixed

The siblings were checked by reading. `RpcTestApp.dispose()`,
`RpcHttpServer.stop()` and the websocket server each claim their teardown
synchronously, before the first await, so a second concurrent call cannot
repeat it.

## Links

Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [..., 722]`.
Bench `../probes/P-237-stop-during-start.md` — new arm.
