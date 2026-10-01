---
status: closed (round 596)
round: 508 (measured as part of B-117; split out in the round-540 bookkeeping pass)
commit: 6659c0ee
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
probe: P-146
reason: "REFUTED in round 596: the wrapper forwards only what the core broadcasts, and the core stopped broadcasting routed responses in round 508, so 0.00 events per call reach the second broadcast (control with that skip off: 3.00 per unary, 101.00 per stream). Previously: cost — the core channel transport stopped broadcasting what it had already routed; the websocket wrapper still re-broadcasts every message with a set lookup each, and only the core half was varied"
---

# B-203 — the websocket wrapper re-broadcasts every frame the core transport already routed

Split out of B-117, which round 508 closed by skipping the global broadcast for a message
already delivered to its own per-stream controller. Bench
`../probes/P-146-how-many-times-is-a-frame-dispatched.md`.

**Only the core channel transport was varied.** `RpcWebSocketCallerTransport._attach`
listens to the inner transport's `incomingMessages` and re-adds every message into its own
`_incomingCtl`, with a `_peerStreamIds` set lookup per message on the way. That second
broadcast exists to keep `incomingMessages` stable across a reconnect, which is a real
requirement — so the question is not whether to remove it but what it costs now that the
layer below no longer duplicates.

**And a design question the same lead raised.** With the message half no longer needed by a
caller, `startCallerListening` exists purely to keep the buffered broadcast drained and to
observe errors — two responsibilities on one stream. Separating them has no measured
failure behind it.

## Why it matters

The priority transport pays a per-message cost the core transport was just relieved of, and
nothing has measured it.

## Witness a round would build

P-146's counting shape, applied one layer up: dispatches per message through
`RpcWebSocketCallerTransport` against the same call through the bare channel transport.
The reconnect requirement is the control — `incomingMessages` must survive a reconnect
either way.

## Round 596 — refuted

```
                                    per unary call   per 100-message stream
WRAPPER  RpcWebSocketCallerTransport       0.00              0.00
CONTROL  bare RpcChannelTransport          0.00              0.00
ABLATED  core skip off, either             3.00            101.00
```

`../rounds/596-the-rebroadcast-that-carries-nothing.md`, `../checked/C-62-the-websocket-rebroadcast-carries-nothing.md`.

## Owner decision

—
