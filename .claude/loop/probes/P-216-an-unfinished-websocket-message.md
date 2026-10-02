---
file: packages/transport/rpc_dart_websocket/test/an_unfinished_message_is_bounded_test.dart
round: 611
commit: 2d00c669
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart]
status: valid (round 611)
---

# P-216 — an unfinished WebSocket message

## Why it exists

B-202: dart:io assembles a whole WebSocket message before delivering it. What
bounds a message whose final fragment never arrives?

## The harness

A real `RpcWebSocketServer` over `rpcWebSocketConnections` with
`maxMessageLengthBytes` 1 MiB. The client is a raw `Socket` that does the HTTP
upgrade by hand and writes 1 MiB continuation frames with FIN clear, all from
one reused buffer, so the client side holds nothing. It reads two things: whether
the server closes the socket, and after how many fragments; and RSS growth across
the run (client and server share the process).

## The numbers (round 611)

```
                                   fragments   closed after   RSS
before, 64 x 1 MiB                      64       never        +34 MiB
before, 256 x 1 MiB                    256       never       +147 MiB
after,  64 x 1 MiB                      64       1            +11 MiB
canary (guard admits all)               64       never        +50 MiB
```

Round 624 added a second arm: the upgrade request and a header declaring 2^40
bytes in ONE write. Before: the process exits with `Bad state: Stream is already
closed`. After: the socket closes and the server stays up. The first arm's
threshold is `closedAfter <= 8`: Linux CI read 3 where macOS reads 1, the client
noticing the close a few writes late.

## Measures

Whether one connection can make the server buffer an unbounded message.

## Control

`oversized_message_is_refused_test.dart`: a whole message under the policy is
still accepted (three 4 MiB messages, 16 MiB policy), and one over it is still
closed with 4400 by the multiplexer.
