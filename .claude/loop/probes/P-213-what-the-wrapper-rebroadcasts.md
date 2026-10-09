---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b203_what_the_wrapper_rebroadcasts.dart
round: 596
commit: e3c9e358
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid (round 596)
---

# P-213 — what the websocket wrapper rebroadcasts

## Why it exists

B-203: does `RpcWebSocketCallerTransport` still forward every frame through its
second broadcast?

## The harness

A real `RpcWebSocketServer` on loopback. Counts events on the transport's
`incomingMessages` across 500 unary calls and 50 server streams of 100 messages,
after a warm-up, for the wrapper and for a bare `RpcChannelTransport` over the
same kind of socket.

## The numbers (round 596)

```
                                    per unary call   per 100-message stream
WRAPPER                                    0.00              0.00
bare channel transport                     0.00              0.00
core skip ablated, either                  3.00            101.00
```

## Measures

Messages the transport broadcasts on `incomingMessages` per call.

## Control

Round 508's routed-message skip in `RpcChannelTransport._onMessage` forced off in
place: every frame of a call appears.

## Reading

rpc_dart_websocket — events on `incomingMessages` per call over a real socket:
`0.00` per unary and per 100-message stream for the wrapper and a bare channel
transport; `3.00` / `101.00` with round 508's routed-message skip forced off,
which is the control
