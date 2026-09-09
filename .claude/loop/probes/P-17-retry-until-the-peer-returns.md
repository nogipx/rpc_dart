---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/retry_until_the_peer_returns.dart
round: 238 — the validating round
commit: 9cbd2d47
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/resilience/**]
status: valid
---

# P-17 — does the recovery API work more than once?

A real WebSocket server that can be taken DOWN and brought back on the SAME
port, so the client's reconnect factory keeps pointing somewhere real. Per
cycle: stop the server, call `reconnect()` four times into the dead peer, bring
it back, reconnect, make a call. **Two full cycles**, because a flag that
conflates two meanings goes wrong on the second pass rather than the first —
which is the lens's give-away, "a recovery API that works exactly once". Run it
with `melos exec --scope=rpc_dart_websocket -- fvm dart run
.dart_tool/probe/retry_until_the_peer_returns.dart`.

## Measures

Three booleans per cycle, all read from the library. **allRefusalsRecoverable** —
every failed attempt reported `supported: true`, i.e. told the caller it may try
again. **recovered** — the attempt after the server returns is healthy.
**callWorks** — a real unary call succeeds afterwards.

Plus **serverUp**, checked with a plain `Socket.connect` independent of
rpc_dart. That column exists because the rig lied once: see below.

## Control

The `_disconnected` split ablated in `_reconnectOnce`'s catch — `_closed = true`
instead, which is the pre-63aa8e93 shape of one flag for both meanings:

```
  as shipped   cycle 1  recoverable=true   recovered=true   callWorks=true
               cycle 2  recoverable=true   recovered=true   callWorks=true

  ablated      cycle 1  recoverable=false  recovered=false  callWorks=false
               cycle 2  recoverable=false  recovered=false  callWorks=false
                        health: "Transport closed"
```

**The FIRST ablation attempt moved nothing**, and that is worth keeping: it
removed the `_disconnected` branch from `health()`, which this probe never
reads — it reads what `reconnect()` returns, and that has its own
`supported: true`. Ablate the observable the bench actually samples, or the
control silently proves nothing.

> **The rig lied before the library did.** A first version built a fresh
> `RpcCallerEndpoint` per call and closed it; `RpcEndpointBase.close()` closes
> the TRANSPORT it was given, so the probe shut its own client down at the end
> of cycle 1 and cycle 2 read "Transport closed" — indistinguishable from the
> defect being hunted. The `serverUp` column and printing the health message are
> what separated them.

Lens: `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md`.
