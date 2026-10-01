---
round: 596
commit: e3c9e358
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
scope: what RpcWebSocketCallerTransport forwards on its incomingMessages per ordinary call, unary and server-stream
---

# C-62 — the websocket wrapper's rebroadcast carries nothing on an ordinary call

B-203 claimed the wrapper re-broadcasts every frame the core transport already
routed. Measured over a real socket: **0.00 events per unary call and per
100-message server stream**, on the wrapper and on a bare channel transport alike.

## Control

Round 508's skip in `RpcChannelTransport._onMessage` forced off: `3.00` per unary
call and `101.00` per stream on both. The bench sees every frame when the core
broadcasts it; the core no longer does for a routed response, so the wrapper has
nothing to forward.

## What it licenses

Not re-measuring this cost while the core skip stands. The wrapper still forwards
peer-initiated and un-routed messages, which is the stable-across-reconnect
requirement it exists for.

## What it does not

The design question on `startCallerListening` (drain the buffer, observe errors)
is untouched: no failure was found or sought.

`../probes/P-213-what-the-wrapper-rebroadcasts.md`,
`../rounds/596-the-rebroadcast-that-carries-nothing.md`.
