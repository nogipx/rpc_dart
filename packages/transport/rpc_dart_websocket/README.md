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

## Serving (VM)

`package:rpc_dart_websocket/io.dart` owns the HTTP-upgrade seam, which is where
every server-side decision has to be made:

```dart
final http = await HttpServer.bind(host, port);
final server = RpcWebSocketServer(
  connections: rpcWebSocketConnections(
    http,
    pingInterval: const Duration(seconds: 30),
    allowedOrigins: {'https://app.example.com'},
  ),
  onEndpointCreated: (endpoint) => endpoint.registerServiceContract(MyApi()),
);
```

- `allowedOrigins` — **set this if browsers reach your server.** WebSocket is
  not subject to the same-origin policy: any page can open a socket to your
  server and the browser attaches the user's cookies. Checking `Origin` at the
  handshake is the only protocol-level defence. Requests with no `Origin` (every
  non-browser client) are allowed; see the API docs for why.
- `allowUpgrade` — the general form, for a token in the query string, a header,
  or a path check. Synchronous, because it runs in the accept path.
- `pingInterval` — half-open detection. Without it a server keeps every dead
  connection, and its contracts, forever.
- `compression` — permessage-deflate, OFF by default because it is an unbounded
  decompression bomb from an unauthenticated peer.

## Deploy behind a proxy that bounds the frame

`RpcSecurityPolicy.maxMessageLengthBytes` is enforced by rpc_dart's frame layer,
which runs **after** the WebSocket implementation has assembled the message.
`dart:io` buffers a whole message before the frame layer sees its first byte, so
the ceiling refuses the message only once the memory has already been spent.
Measured: a peer sending **96 MiB in one WebSocket message** delivers it as a
single 96 MiB chunk, whatever `maxMessageLengthBytes` says.

That is the wrong order for an unauthenticated peer, and rpc_dart cannot fix it
from inside: the bytes are in the socket layer's buffer before any of this
package's code runs.

So put a frame or message size limit in the proxy in front of the server —
nginx's `client_max_body_size` / a WebSocket-aware `proxy_*` bound, Envoy's
`max_request_bytes`, an ALB rule — set at or below your
`maxMessageLengthBytes`. The policy then becomes a second line of defence rather
than the only one.

There is also **no limit on the number of connections**. `RpcWebSocketServer`
builds one endpoint per accepted socket and keeps it until the socket closes or
the keepalive reclaims it; bound the count upstream if the server is exposed.
