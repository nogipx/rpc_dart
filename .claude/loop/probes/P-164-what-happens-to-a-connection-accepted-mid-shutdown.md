---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b135_start_during_stop.dart
round: 531
commit: cbfaa66a
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
status: valid
---

# P-164 — what happens to a connection accepted mid-shutdown?

## Why it exists

A shutdown has two phases and a restart landing in either one leaves a different wreck, so a
single "did it break" arm cannot describe it. The rig puts a fresh connection in each phase in
turn and asks what became of it.

## The harness

`RpcWebSocketServer` over a `StreamController<WebSocketChannel>`, so connections arrive on
command. One incumbent connection makes the shutdown slow enough to aim at, then `stop()` runs
unawaited, `start()` is called inside it, and a fresh channel is fed in.

**The drain phase needs a REAL in-flight call.** With none, `_drain` returns on its first poll
and the arm silently becomes a second copy of the close-phase arm — which is exactly what the
first version of this probe did, reporting identical rows for two different questions. So the
drain arm builds a caller over a wired channel pair and leaves a slow unary call open.

## Measures

The KIND of close the fresh channel got, not a boolean: **refused** (answered outright, close
carries a reason), **torn down** (closed by the shutdown that was already running), or
**never** (no close at all). A boolean cannot tell the first two apart, and they are different
defects. Plus how many endpoints the server is still holding, which is what separates "closed"
from "forgotten".

## The numbers (round 531)

```
  fresh connection arrives   server running   the fresh one   endpoints held
  drain                      true             torn down       0
  close                      true             never           0
  after                      true             never           1
  nothing                    true             never           1
```

After the fix every row reads `never / 1`.

## Control

**`after` — the ordinary restart, which waits for the stop — and `nothing`, which never stops
at all.** Without them, `endpoints held: 0` is equally consistent with a rig that never
delivered a connection, and the whole table would mean nothing. That was a real risk: the
first version had no such arm and read 0 everywhere.

## What it establishes, and what it does not

Establishes: a restart inside the drain phase hands its new connection to the old shutdown,
which closes it while the server reports running; a restart inside the close phase leaves the
new endpoint dropped by `_endpoints.clear()` and never closed, held by nothing.

Does NOT use real sockets. Every channel is in-memory, so nothing here says what the peer
observes at the TCP level — only whether this server closed it and whether it still knows it
exists.

Does NOT measure how wide the windows are in a deployment. Both are made wide on purpose (a
slow close, a slow handler); how likely a supervisor is to land in one is not addressed.

## Reading

rpc_dart_websocket — **reads the KIND of ending, not a boolean**: refused,
torn down, or never closed. A shutdown has two phases and each wrecks a
connection differently, so one "did it break" arm describes neither. **Its
drain arm needs a REAL in-flight call** — the first version had none, so the
drain returned on its first poll and the arm became a duplicate of the next
one, two identical rows reading as a consistent finding rather than a broken
rig. Controls: a restart that WAITS, and a server that never stops — without
them "held nothing" is indistinguishable from "delivered nothing".
