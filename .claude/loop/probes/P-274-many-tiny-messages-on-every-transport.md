---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r776_many_tiny_messages.dart
round: 776
commit: 8d804d9f
paths: [packages/core/rpc_dart/lib/src/core/parser.dart, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_isolate/lib/**]
status: valid
---

# P-274 — many tiny messages on every transport

## Measures

Default policies. Per transport: a server stream of N empty messages and a
client-stream upload of N empty messages (env N, 3000), read throughout.
Printed: messages that arrived, or the error.

The question is `maxMessagesPerChunk` (1024): can an honest sender put
more than that many messages into one inbound chunk? Each gRPC message is
at least 5 bytes, so one 16 KiB HTTP/2 DATA frame could carry 3276.

## Control

The transports that deliver one message per frame (websocket, isolate):
any refusal there would not be the per-chunk count.
