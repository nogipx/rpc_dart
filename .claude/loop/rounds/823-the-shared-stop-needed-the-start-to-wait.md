---
round: 823
verdict: FIXED
packages: [rpc_dart_http, rpc_dart_http2]
lens: RPC-21
bench: none — the witness test is the measurement; the probe is below
commit: yes
severity: S3
release: changelog
---

# Round 823 — the shared stop needed the start to wait

## Target

Round 822's own fix, and its `## Not fixed`: `RpcHttpServer.start()` does
not wait for a stop in flight, where the websocket server's does. With
`stop()` now sharing one future, that gap changes meaning.

## Hypothesis

A restart during a drained stop, followed by a `stop()`, gets the FIRST
stop's future back from `_stopping ??=`, so the restarted server is never
stopped. Round 822 introduced this on http and http2.

## Before

Probe `packages/transport/rpc_dart_http/.dart_tool/probe/r823_restart_during_drain.dart`
(a fixed port, one in-flight call, `stop(drainTimeout: 3 s)`, then
`start()`, `afterModulesStart()`, `stop()`):

```
  arm                          after the last stop
  restart after the drain      isRunning false, a call gets RpcStatusException  (control)
  restart during the drain     isRunning true,  a call gets 'z' (still serving)
```

## Mechanism

As hypothesised: the last `stop()` found `_stopping` set by the draining
stop and returned it; that stop had captured the OLD listener and endpoint,
so the new ones were never closed.

## Fix

`start()` awaits `_stopping` first, on http and http2, as
`RpcWebSocketServer.start()` already does.

## After

```
  restart during the drain     isRunning false, a call gets RpcStatusException
```

Witness in both packages' `graceful_drain_on_stop_test`: "a restart during a
drain is stopped by the next stop".

## Canary

The await switched off (`stopping != null && 1 < 0`) on each: the witness
fails, `Expected: false Actual: <true>`, "the last stop returned the first
stop and left this running". Restored.

## The verdict questions

1. Only when the restart lands differs.
2. Yes: running against stopped.
3. On the server: `isRunning`, and whether a call is answered.
4. One arm each; the outcome is binary.
5. Quoted.
6. Two sites, two canaries.
7. From the probe.
8. The regression is round 822's; it was found by reading that round's
   `## Not fixed` as a target.
9. none.
10. Siblings below.
A1. n/a. A2. Ordering. L1. n/a.

## Gate

`melos run analyze` and `test:unit` green.

## Siblings

- websocket: already waits (`start()` awaits `_stopping`), and its `stop()`
  publishes `_stopping` before the first await
- http, http2: fixed here
- isolate, wasm, channel: n/a, no drained server lifecycle

## Not fixed

none.

## Links

Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md`. Previous round
`822-a-second-stop-returned-during-the-drain.md`.
