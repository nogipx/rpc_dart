---
status: closed (round 531)
round: 531
commit: cbfaa66a
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
probe: P-164
reason: "CONFIRMED in both halves, one per shutdown phase, and FIXED by serialising: `stop()` publishes its attempt before the first await and `start()` awaits it"
---

# B-135 — RpcWebSocketServer.start() during a draining stop()

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**low-medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`start()` sets `_isRunning = true` at once because `_connectionsSub` survives `stop()`; the still-running stop then closes connections accepted after the restart, and `_endpoints.clear()` drops ones added during the close loop without closing them.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart:194-203`.

## Why it matters

Leaked endpoints and dropped fresh connections on a quick restart.

## What round 531 measured

```
  fresh connection arrives   server running   the fresh one   endpoints held
  drain                      true             torn down       0
  close                      true             never           0
  after                      true             never           1
  nothing                    true             never           1
```

Bench `../probes/P-164-what-happens-to-a-connection-accepted-mid-shutdown.md`. After the fix
every row reads `never / 1`.

Both halves confirmed, one per phase. The close-phase row is the worse one: nothing holds that
endpoint, so no later `stop()` or `dispose()` can reach it.

**The drain arm was silently wrong first.** With no in-flight call `_drain` returns on its
first poll, so the arm became a second copy of the close arm — two identical rows reading as a
consistent result rather than as a broken rig. The lead's FIRST claim was only confirmed once a
real slow call was built.

## Fix

The first option: serialise. `stop()` publishes its attempt in `_stopping` before its first
await, and `start()` awaits it. A peer arriving in between is refused by `_handleConnection`,
which already ANSWERS it — so "refuse start while stopping" was unnecessary, the refusal is
already at the right layer.

**Behaviour change**: `start()` can now block for the whole drain budget. Wants a CHANGELOG
line.

Not done: single-flighting overlapping `stop()` calls. A second stop with a different budget
returns immediately because `_isRunning` is already false, so its budget is ignored — deciding
what that should mean is a design question.

## Owner decision

—
