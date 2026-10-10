---
round: 822
verdict: FIXED
packages: [rpc_dart_http, rpc_dart_websocket, rpc_dart_http2]
lens: RPC-21
bench: P-305 — new
commit: yes
severity: S3
release: changelog
---

# Round 822 — a second stop returned during the drain

## Target

RPC-21 (#2, last applied in round 777) on the servers' `stop(drainTimeout)`.
Round 722 made concurrent `RpcApp.stop()` calls share one future and
checked the transport servers by reading: "each claims its teardown
synchronously, so a second concurrent call cannot repeat it". Not repeating
the teardown is half of it; the other half is when the second call
returns.

## Hypothesis

A second `stop()` during a drain finds the teardown already claimed and
returns at once, so its caller goes on (exits, restarts, reports stopped)
while the first is still answering in-flight calls.

## Before

```
P-305: one in-flight call (1 s), two concurrent stop(drainTimeout: 3 s)
  http        returned at 890 ms and 2 ms
  websocket   returned at 844 ms and 1 ms
  control (one stop): 878 / 868 ms
```

http2 read: `stop()` returns on `!_isRunning`, which the first stop clears
before its drain; its witness below fails the same way.

## Mechanism

As hypothesised. http and http2 take their fields (or clear `_isRunning`)
before the first await, and the websocket server's `stop()` returns
`Future.value()` on `!_isRunning`, which `_stopOnce` clears on its first
line. Its `_stopping` future existed, but only `start()` read it.

## Fix

- http, http2: `stop()` returns `_stopping ??= _stop(...).whenComplete(...)`,
  `RpcApp`'s idiom. A second call's `drainTimeout` is not used; it shares
  the first.
- websocket: `if (!_isRunning) return _stopping ?? Future.value()`.

## After

```
  http        2 stops   894, 894 ms   call ok
  websocket   2 stops   850, 850 ms   call ok
```

Witness in each package's `graceful_drain_on_stop_test`: "a second stop
during a drain waits for it".

## Canary

Each fix switched off in place (`1 > 0 ? _stop(...) : ...`, and
`1 > 0 ? Future.value() : _stopping!`): all three witnesses fail with
`Expected: true Actual: <false>`, "the second stop returned while the first
was still draining". Restored.

## The verdict questions

1. Only the number of concurrent stops differs.
2. Yes: 2 ms against 890 ms.
3. At the caller of the second stop: when its future completed.
4. Two servers measured, three witnesses.
5. Quoted.
6. Three sites, three canaries.
7. From the numbers.
8. Round 722's reading of these siblings was wrong in this half; recorded
   here.
9. none.
10. Siblings below.
A1. n/a. A2. Ordering. L1. n/a.

## Gate

`melos run analyze` and `test:unit` green.

## Siblings

- http, websocket: fixed here
- http2: fixed here (low priority, the same one-line class)
- isolate, wasm, channel: n/a, no server with a drained `stop()`
- caller, responder: n/a, server-side lifecycle

## Not fixed

- `RpcHttpServer.start()` during a stop does not wait for it, where the
  websocket server's does; not measured.

CHANGELOG line (each of the three): "`stop()` called while another stop is
draining now completes when that stop does, instead of at once."

## Links

Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md`. Bench
`../probes/P-305-two-stops-during-a-drain.md`. Earlier round
`722-concurrent-stops-share-one.md`.
