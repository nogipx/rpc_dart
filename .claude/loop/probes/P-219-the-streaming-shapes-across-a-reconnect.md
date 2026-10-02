---
file: packages/transport/rpc_dart_websocket/test/a_reused_peer_id_streaming_shapes_test.dart
round: 615
commit: e3c2e4b1
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/core/rpc_dart/lib/src/core/buffered_broadcast.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid (round 615)
---

# P-219 — the streaming shapes across a reconnect

## Why it exists

B-212: round 541 gave the four streaming shapes' tail cleanup `only:` by
inspection, and P-174 drove only unary. This drives server-stream,
client-stream and bidi the same way.

## The harness

P-174's rig, with the contract carrying three streaming methods. A server peer
calls a method registered on the CLIENT peer; the handler parks on a gate. The
client reconnects, the server's fresh endpoint opens the next call on the same
stream id, and the parked answer is released first. Each request stream is left
open so the handler parks with a live request feed. The guard arm makes both
calls on one connection without a reconnect.

## The numbers (round 615)

```
                 reconnect: second caller   cancelled   guard: second caller
server-stream    answered two               [one]       answered two
client-stream    answered two               [one]       answered two
bidi (before)    answered two               [one]       TIMEOUT, started [one]
bidi (after)     answered two               [one]       answered two
```

The bidi guard is what found the defect in round 615. Its minimal form,
`a_peer_client_gets_every_bidi_request_test.dart`, reads
`TIMEOUT | TIMEOUT | started []` with the fix off: not even the first call is
served.

## Measures

What a second caller on a reused or a fresh peer id receives, and whether the
parked handler is told.

## Control

The guard arm, and the same two bidi calls served by the server side over the
same socket, which were always answered.
