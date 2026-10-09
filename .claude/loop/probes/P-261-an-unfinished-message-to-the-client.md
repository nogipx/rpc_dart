---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r756_unfinished_message_to_client.dart
round: 756
commit: 8dcf442f
paths: [packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
status: valid
---

# P-261 — an unfinished message to the client

P-216's mirror: the server is the hostile side. A raw socket server does the
upgrade by hand and writes N unmasked 1 MiB fragments with FIN clear, from one
reused buffer; the client is `RpcWebSocketCallerTransport.connect` with its
defaults. Run from the repo root:
`fvm dart run packages/transport/rpc_dart_websocket/.dart_tool/probe/r756_unfinished_message_to_client.dart <fragments>`.

`r756_throughput.dart` beside it times 5000 small unary calls and a 200 x
256 KiB server stream over a real socket, for the guard's cost.

## Measures

Fragments written before the server saw the socket close, whether the client
transport reports closed, and process RSS growth (client and server share it;
the server holds one buffer).

## Control

N is the variable: 4 fragments against 256. Before the fix RSS grows with N
(+15 against +354 MiB) and nothing closes, so the bench sees unbounded
buffering. After, 4 fragments, under the ceiling, are still not closed.
