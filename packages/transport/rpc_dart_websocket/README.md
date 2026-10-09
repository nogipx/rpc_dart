<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_websocket

WebSocket transport for [`rpc_dart`](https://pub.dev/packages/rpc_dart). It runs
on the VM and on the web (dart2js and Wasm) and supports all four call kinds
(unary, server stream, client stream, bidirectional) over one socket.

This is the rpc_dart frame protocol over WebSocket, not gRPC. Both peers must be
rpc_dart. For gRPC wire compatibility use `rpc_dart_http2`.

Contracts, endpoints, errors and `RpcSecurityPolicy` are documented in
`rpc_dart`. This README covers only what is specific to WebSocket.

## Install

```yaml
dependencies:
  rpc_dart_websocket: ^0.5.0
```

Two libraries:

- `package:rpc_dart_websocket/rpc_dart_websocket.dart` — web-safe. Client
  transport, server, responder transport, raw channel.
- `package:rpc_dart_websocket/io.dart` — VM only. `rpcWebSocketConnections`,
  which turns a `dart:io` `HttpServer` into connections for the server.

## Client

`connect` is async. It completes once the WebSocket handshake is done, and
throws if the server is unreachable or refuses the upgrade.

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';

Future<void> client() async {
  final transport = await RpcWebSocketCallerTransport.connect(
    Uri.parse('wss://api.example.com/rpc'),
  );
  final endpoint = RpcCallerEndpoint(transport: transport);

  // ... make calls through a generated caller or the endpoint ...

  await endpoint.close(); // closes the transport and the socket
}
```

### Options

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';

Future<RpcWebSocketCallerTransport> connectWithOptions(
  Future<String> Function() fetchToken,
) {
  return RpcWebSocketCallerTransport.connect(
    Uri.parse('wss://api.example.com/rpc'),
    protocols: ['rpc-v1'],
    policy: const RpcSecurityPolicy(),
    pingInterval: const Duration(seconds: 30),
    connectTimeout: const Duration(seconds: 10),
    headersProvider: () async => {
      'Authorization': 'Bearer ${await fetchToken()}',
    },
  );
}
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `protocols` | none | `Sec-WebSocket-Protocol` values to offer. |
| `policy` | `RpcSecurityPolicy()` | Limits applied to this connection. |
| `pingInterval` | off | Keepalive. See below. |
| `enableCompression` | `false` | Offer permessage-deflate. See below. |
| `headers` | none | Headers on the upgrade request. VM only. |
| `headersProvider` | none | Called for the first upgrade and for every reconnect. Use it for tokens that expire. Pass `headers` or `headersProvider`, not both. |
| `connectTimeout` | 30 s | Bounds the whole open and every reconnect, on both platforms. `null` waits without a bound: a server that accepts TCP and never completes the upgrade then holds `connect` forever. |

**Keepalive.** A half-open connection (a NAT, load balancer or mobile network
that stops forwarding without closing) is detected only by `pingInterval`.
Without it a call on a dead path hangs and `health()` still reports healthy. On
the VM `dart:io` sends the pings. In the browser, which hides WebSocket
ping/pong from the page, the transport runs its own ping at the same interval
and closes the socket when one goes unanswered. Pick about half the shortest
idle timeout on the network path.

**Headers in the browser.** The browser WebSocket API cannot set request
headers, so `headers` and `headersProvider` are ignored there (not rejected).
Authenticate a web client with a cookie, a `Sec-WebSocket-Protocol` value or a
query parameter.

**Compression.** Off by default. With it on, `dart:io` inflates each incoming
message without an output limit before rpc_dart sees it, so a hostile server can
send a small compressed message that expands to hundreds of MiB. Enable it only
against servers you control.

If you build the `WebSocketChannel` yourself, wrap it with the constructor:
`RpcWebSocketCallerTransport(channel, reconnectFactory: ..., pingInterval: ...)`.
Here `pingInterval` runs the library's own ping. If the channel already has a
native ping (`IOWebSocketChannel.connect(url, pingInterval: ...)`), leave
`pingInterval` null or pass `platformHandlesPing: true`.

### Reconnect

The transport implements `IRpcReconnectableTransport`. `reconnect()` opens a new
socket with the same options (headers included) and keeps the same transport
object and `incomingMessages` stream, so endpoints built on it stay valid.
Concurrent `reconnect()` calls share one attempt. It returns a health status and
does not throw.

```dart
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';

Future<bool> tryReconnect(RpcWebSocketCallerTransport transport) async {
  final status = await transport.reconnect();
  return status.isHealthy;
}
```

When the socket drops, the transport stays open for `reconnect()` and emits one
event on `connectionLost` (`IRpcConnectionLossReporting`); `incomingMessages`
neither ends nor errors. Calls in flight when the socket drops are lost; only
new calls use the new socket.

For automatic reconnect with backoff, give `RpcClientConnection` from `rpc_dart`
a factory that calls `RpcWebSocketCallerTransport.connect`. The connection
reconnects on that event.

## Server

`RpcWebSocketServer` consumes a `Stream<WebSocketChannel>` of already-upgraded
connections. It creates one endpoint per connection and closes it when the
socket closes. The HTTP upgrade happens outside it.

### With dart:io (`io.dart`)

`rpcWebSocketConnections` performs the upgrade and is where server-side checks
are made.

```dart
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';

Future<RpcWebSocketServer> serve(RpcResponderContract service) async {
  final http = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
  final server = RpcWebSocketServer(
    connections: rpcWebSocketConnections(
      http,
      allowedOrigins: {'https://app.example.com'},
    ),
    maxConnections: 1000,
    onEndpointCreated: (endpoint) => endpoint.registerServiceContract(service),
  );
  await server.start();
  return server;
}
```

`rpcWebSocketConnections` parameters:

- `allowedOrigins` — set this if browsers reach your server. WebSocket is not
  subject to the same-origin policy: any page can open a socket to your server,
  and the browser attaches the user's cookies. Checking `Origin` at the handshake
  is the only protocol-level defence. Compared case-insensitively against
  `scheme://host[:port]`. Requests without `Origin` (non-browser clients) are
  allowed.
- `allowUpgrade` — a synchronous `bool Function(HttpRequest)` for anything else:
  a token in the query string, a header, a path. Runs after `allowedOrigins`;
  both must accept. A refused request gets `403` and is never upgraded.
- `pingInterval` — default 30 s. Detects peers that went silent; without it a
  dead connection and its contracts are kept forever (`HttpServer.idleTimeout`
  does not apply to an upgraded socket). Pass `null` to disable.
- `compression` — default off (`dart:io` defaults to on). With it on, a peer can
  send a small message that inflates without limit before any rpc_dart check,
  and the frame checks below do not run at all: no per-message ceiling, and no
  limit on inbound pings, each of which dart:io answers with a pong queued for
  a client that may never read it.
- `protocolSelector` — subprotocol negotiation, as in `WebSocketTransformer`.
- `policy` — the message-size ceiling for the upgrade. By default the server's
  `policy` is used, handed over when the server starts.

With compression off, each WebSocket frame header is checked as it arrives: a
message larger than the policy allows closes the connection before its payload
is buffered, and so does a client pinging faster than 16 times a second after
a burst of 256.

### With another HTTP stack

Any source of `WebSocketChannel`s works. With `shelf_web_socket`, plus
`createWithContracts` when every connection gets the same contracts:

```dart
import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

Future<void> serveWithShelf(List<RpcResponderContract> contracts) async {
  final connections = StreamController<WebSocketChannel>();

  final server = RpcWebSocketServer.createWithContracts(
    connections: connections.stream,
    contracts: contracts,
  );
  await server.start();

  await shelf_io.serve(
    webSocketHandler(
      (WebSocketChannel channel, String? protocol) => connections.add(channel),
      allowedOrigins: ['https://app.example.com'],
      pingInterval: const Duration(seconds: 30),
    ),
    '0.0.0.0',
    8080,
  );
}
```

This path has no frame-header check: the WebSocket library buffers a whole
message before rpc_dart sees it. See "Deploy behind a proxy" below.

### Per-connection setup and callbacks

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

RpcWebSocketServer buildServer(
  Stream<WebSocketChannel> connections,
  RpcResponderContract Function() createService,
) {
  return RpcWebSocketServer(
    connections: connections,
    policy: const RpcSecurityPolicy(),
    maxConnections: 1000,
    onEndpointCreated: (endpoint) {
      endpoint.registerServiceContract(createService());
    },
    onConnectionOpened: (channel) => print('connected'),
    onConnectionClosed: (channel) => print('disconnected'),
    onConnectionError: (error, stackTrace) => print('connection error: $error'),
  );
}
```

| Parameter | Meaning |
| --- | --- |
| `connections` | Required. Upgraded sockets. The server listens to it once, on the first `start()`. |
| `policy` | Limits for every connection. Also handed to `rpcWebSocketConnections`. |
| `maxConnections` | Default `null` (no limit). At the limit a new socket is closed immediately. |
| `onEndpointCreated` | Called with each `RpcResponderEndpoint`; register contracts here. |
| `onPeerEndpointCreated` | Use instead of `onEndpointCreated` to get an `RpcPeerEndpoint` per connection, which can both serve and call the client. Passing both throws `ArgumentError`. |
| `onConnectionOpened` / `onConnectionClosed` / `onConnectionError` | Notifications. An exception thrown in one is logged and does not stop the server. |
| `logger` / `logController` | Logging, see `rpc_dart_log`. |

`server.endpoints` lists responder endpoints only; it is empty in peer mode.

### Stopping

`stop()` refuses new connections and closes every open one at once; calls in
progress fail with a retryable `UNAVAILABLE`. `stop(drainTimeout: ...)` first
waits up to the timeout for in-flight calls to finish. A stopped server can be
started again on the same `connections` stream. `dispose()` stops it and
releases the stream for good; call it when the server will not be restarted.

## Deploy behind a proxy that bounds the message size

`RpcSecurityPolicy.maxMessageLengthBytes` is checked by rpc_dart after the
WebSocket library has assembled a message. Where that library buffers the whole
message first, the limit refuses an oversized message only after the memory is
spent. That is the case for:

- `rpcWebSocketConnections` with `compression` on,
- any other connection source (`shelf_web_socket`, your own
  `WebSocketTransformer`),
- the client, for messages from the server.

For a server exposed to untrusted peers on one of these paths, put a message or
frame size limit in the proxy in front of it (an nginx, Envoy or load-balancer
rule) at or below your `maxMessageLengthBytes`.

`maxConnections` is off by default. Set it, or bound connections upstream, if
the server is exposed: each accepted socket holds an endpoint until it closes or
the keepalive reclaims it.

## Lower level

- `RpcWebSocketResponderTransport(channel, policy: ...)` — server-side transport
  for one connection, if you manage endpoints yourself.
- `RpcWebSocketChannel(webSocketChannel)` — the raw `IRpcChannel`, for
  `RpcChannelTransport.fromChannel`.
- `RpcWebSocketNonBinaryFrame` — what arrives on `incomingMessages` when the
  peer sends a text frame. It does not fail calls.
