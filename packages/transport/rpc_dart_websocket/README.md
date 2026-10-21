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
) async {
  return RpcWebSocketCallerTransport.connect(
    Uri.parse('wss://api.example.com/rpc'),
    protocols: ['rpc-v1'],
    policy: const RpcSecurityPolicy(),
    pingInterval: const Duration(seconds: 30),
    connectTimeout: const Duration(seconds: 10),
    headers: {'Authorization': 'Bearer ${await fetchToken()}'},
  );
}
```

| Parameter | Default | Meaning |
| --- | --- | --- |
| `protocols` | none | `Sec-WebSocket-Protocol` values to offer. |
| `policy` | `RpcSecurityPolicy()` | Limits applied to this connection. |
| `pingInterval` | off | Keepalive. See below. |
| `enableCompression` | `false` | Offer permessage-deflate. See below. |
| `headers` | none | Headers on the upgrade request. VM only. For a token that expires, read it in the `RpcClientConnection` factory, which calls `connect` once per attempt. |
| `connectTimeout` | 30 s | Bounds the whole open, on both platforms. `null` waits without a bound: a server that accepts TCP and never completes the upgrade then holds `connect` forever. |
| `cancellationToken` | none | Cancelling it abandons a pending open: the socket closes at once and `connect` throws `RpcCancelledException`. |

**Keepalive.** A half-open connection (a NAT, load balancer or mobile network
that stops forwarding without closing) is detected only by `pingInterval`.
Without it a call on a dead path hangs and `health()` still reports healthy. On
the VM `dart:io` sends the pings. In the browser, which hides WebSocket
ping/pong from the page, the transport runs its own ping at the same interval
and closes the socket when one goes unanswered. Pick about half the shortest
idle timeout on the network path.

**Headers in the browser.** The browser WebSocket API cannot set request
headers, so `headers` are ignored there (not rejected).
Authenticate a web client with a cookie, a `Sec-WebSocket-Protocol` value or a
query parameter.

**Compression.** Off by default. With it on, `dart:io` inflates each incoming
message without an output limit before rpc_dart sees it, so a hostile server can
send a small compressed message that expands to hundreds of MiB. Enable it only
against servers you control.

With compression off (VM), `connect` checks each incoming frame header as it
arrives, as the server does: a message larger than the multiplexer's
reassembly cap, never below the default policy's, closes the connection before
its payload is buffered. A whole message past a stricter `policy` still fails
only its own call.

If you build the `WebSocketChannel` yourself, wrap it with the constructor:
`RpcWebSocketCallerTransport(channel, pingInterval: ...)`. Here `pingInterval`
runs the library's own ping. If the channel already has a native ping
(`IOWebSocketChannel.connect(url, pingInterval: ...)`), leave `pingInterval`
null or pass `platformHandlesPing: true`.

The channel may still be connecting when you wrap it. The transport's `ready`
completes when the handshake answers and fails if it never does; until then
`health()` reads degraded. `RpcClientConnection` waits on it before it reports
Online.

### Reconnect

One transport is one socket. When the socket drops the transport closes, and
calls in flight on it fail. For reconnects with backoff, give
`RpcClientConnection` from `rpc_dart` a factory that calls
`RpcWebSocketCallerTransport.connect`; build endpoints once on
`connection.transport`. Pass the factory's token through, so `dispose()` closes an upgrade still in flight
instead of leaving its socket open until `connectTimeout`:

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';

RpcClientConnection reconnecting(Uri uri) => RpcClientConnection(
  transportFactory: (cancellation) => RpcWebSocketCallerTransport.connect(
    uri,
    cancellationToken: cancellation,
  ),
);
```

A failed `connect` throws an `RpcStatusException`, as the http caller does:

| Failure | Status |
| --- | --- |
| Upgrade answered 401 / 403 / 404 (VM, compression off) | UNAUTHENTICATED / PERMISSION_DENIED / UNIMPLEMENTED |
| Upgrade answered with another status (VM, compression off) | as `grpcStatusFromHttpStatus` maps it (503 is UNAVAILABLE) |
| Upgrade refused on the web or with compression on | UNAVAILABLE (the platform hides the HTTP status) |
| Connection refused, closed during the upgrade, `connectTimeout` | UNAVAILABLE |

So a `shouldReconnect` can stop on a refusal that a retry will not fix:

```dart
import 'package:rpc_dart/rpc_dart.dart';

bool shouldReconnect(Object? error) =>
    error is! RpcStatusException ||
    (error.statusCode != RpcStatus.unauthenticated &&
        error.statusCode != RpcStatus.permissionDenied);
```

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
  // Bounds each connection's upgrade request; see "Deploy behind a proxy".
  final http = await bindRpcWebSocketHttpServer(InternetAddress.anyIPv4, 8080);
  final server = RpcWebSocketServer(
    connections: rpcWebSocketConnections(
      http,
      allowedOrigins: {'https://app.example.com'},
    ),
    maxConnections: 1000,
    mode: RpcResponderMode.contracts([service]),
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
a burst of 256. And while more than 1 MiB of what the server wrote to a client
is unsent, it stops reading that client, so a client that sends calls and
reads nothing is not answered into memory.

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
message before rpc_dart sees it. See "Deploy behind a proxy" below. Nor does
it stop reading a client that reads nothing: the server's unsent answers to
it are not bounded.

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
    mode: RpcResponderMode((endpoint) {
      endpoint.registerServiceContract(createService());
    }),
    onConnectionOpened: (channel) => print('connected'),
    onConnectionClosed: (channel) => print('disconnected'),
    onConnectionError: (error, stackTrace) => print('connection error: $error'),
  );
}
```

| Parameter | Meaning |
| --- | --- |
| `connections` | Required. Upgraded sockets. The server listens to it once, on the first `start()`. |
| `policy` | Limits for every connection. Also handed to `rpcWebSocketConnections`, but only to the stream it returned: one wrapped with `.where` or `.map` keeps the default frame ceiling, and the server logs a warning when its limit is higher. Filter with `allowUpgrade` and observe with `onConnectionOpened` instead of wrapping. |
| `maxConnections` | Default `null` (no limit). At the limit a new socket is closed immediately. |
| `mode` | Required. `RpcResponderMode(register)` gives each connection an `RpcResponderEndpoint`; `RpcPeerMode(register)` gives it an `RpcPeerEndpoint`, which can both serve and call the client. The register adds the contracts. |
| `onConnectionOpened` / `onConnectionClosed` / `onConnectionError` | Notifications. An exception thrown in one is logged and does not stop the server. Every opened connection is reported closed once. |
| `logger` / `logController` | Logging, see `rpc_dart_log`. |

`server.endpoints` lists the endpoint of every live connection. In peer mode
they are `RpcPeerEndpoint`s, which are `RpcResponderEndpoint`s that can also
call the client.

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

`maxConnections` counts upgraded connections only. Before the upgrade a
connection belongs to your `HttpServer`. A plain `HttpServer.bind` has no limit
on connections and no deadline for a request's headers: a client that keeps its
upgrade request's header block open is held there, at about the size it sent
(up to dart:io's cap of about 3 MiB per block), and `HttpServer.idleTimeout`
does not cover it. Bind it with `bindRpcWebSocketHttpServer` instead, which
bounds the block as `RpcHttpServer` does its own:

| Option | Default | |
| --- | --- | --- |
| `maxHeaderBytes` | 4x what `policy` admits as one request's head | A longer block is cut. |
| `headerTimeout` | 60 s | A block not finished by then is cut; `null` disables it. |
| `maxConnections` | `null` | Open connections at most, upgraded or not; while attackers fill it, honest clients are refused too. |

```dart
import 'dart:io';

import 'package:rpc_dart_websocket/io.dart';

Future<HttpServer> bind() =>
    bindRpcWebSocketHttpServer(InternetAddress.anyIPv4, 8080);
```

Close it as any `HttpServer`. A proxy in front should still limit connections
per client.

## Lower level

- `RpcWebSocketResponderTransport(channel, policy: ...)` — server-side transport
  for one connection, if you manage endpoints yourself.
- `RpcWebSocketChannel(webSocketChannel)` — the raw `IRpcChannel`, for
  `RpcChannelTransport.fromChannel`.
- `RpcWebSocketNonBinaryFrame` — what arrives on `incomingMessages` when the
  peer sends a text frame. It does not fail calls.
