<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_websocket

WebSocket caller/responder transports for `rpc_dart`, web-safe (dart2js and
Wasm) as well as VM.

- `RpcWebSocketCallerTransport` — client transport; `connect()` awaits
  `WebSocketChannel.ready`, and `reconnect()` re-attaches to a fresh socket
  while keeping `incomingMessages` stable across the swap.
- `RpcWebSocketResponderTransport` — server-side transport for one accepted
  connection.
- `RpcWebSocketServer` — an `IRpcServer` that accepts connections and wires an
  endpoint per client.
- `RpcWebSocketChannel` — the raw `IRpcChannel` byte pipe, if you want to build
  the stack yourself via `RpcChannelTransport.fromChannel`.

Multiplexing uses the core 9-byte channel frame (stream id + flags + length),
so all four call kinds share one socket.

## Usage

```dart
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';

final transport = await RpcWebSocketCallerTransport.connect(
  Uri.parse('ws://localhost:8080'),
);
final caller = RpcCallerEndpoint(transport: transport);
```

Unlike `rpc_dart_http2`, this is not the gRPC wire protocol — it is the
rpc_dart frame protocol over WebSocket, so both peers must be rpc_dart.
