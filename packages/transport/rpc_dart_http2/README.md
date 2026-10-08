<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_http2

HTTP/2 caller and responder transports, and a ready server, for [`rpc_dart`].

- All four RPC kinds: unary, server streaming, client streaming, bidirectional.
- Many calls multiplexed over one TCP or TLS connection, with HTTP/2's native
  flow control.
- The gRPC wire format, so it talks to real gRPC clients and servers. See
  [gRPC interop](#grpc-interop).

VM only: it is built on `dart:io` sockets. For browsers use
[`rpc_dart_websocket`] or [`rpc_dart_http`].

Contracts, endpoints, errors and `RpcSecurityPolicy` belong to the core package;
see [`rpc_dart`]. This README covers only what is specific to this transport.

## Install

```yaml
dependencies:
  rpc_dart: ^6.3.0
  rpc_dart_http2: ^0.3.0
```

## Client

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

Future<void> callServer() async {
  // TLS (h2). The port defaults to 443.
  final transport = await RpcHttp2CallerTransport.secureConnect(
    host: 'api.example.com',
  );
  final endpoint = RpcCallerEndpoint(transport: transport);

  final reply = await GreeterCaller(endpoint).hello(
    const RpcString('http2'),
    context: RpcContext.withTimeout(const Duration(seconds: 5)),
  );
  print(reply.value);

  await endpoint.close();
}

// Plaintext (h2c), for local development and internal networks.
// The port defaults to 80.
Future<RpcHttp2CallerTransport> connectLocal() =>
    RpcHttp2CallerTransport.connect(host: 'localhost', port: 8080);
```

`GreeterCaller` and `GreeterResponder` stand for your own contracts.

### Client options

`secureConnect` and `connect` take the same options:

| Option | Default | Meaning |
| --- | --- | --- |
| `host` | required | Server host; also sent as `:authority`. |
| `port` | 443 / 80 | |
| `policy` | `const RpcSecurityPolicy()` | Limits on what the server may send, and `maxActiveStreams` for concurrent calls. |
| `connectTimeout` | 30 s | Bound on opening the socket, TLS handshake included. `null` waits for the OS. |
| `proxyUri` | `null` | HTTP CONNECT proxy, e.g. `http://user:pass@proxy:3128`. Credentials come from the URI's user info. |
| `proxyHandshakeTimeout` | 30 s | Bound on the proxy's answer to `CONNECT`. |
| `pingInterval` | `null` (off) | Sends an HTTP/2 PING this often. The only way the client notices a half-open connection. |
| `pingTimeout` | `pingInterval` | How long to wait for the PING ACK before the connection is torn down. |
| `logger` | `null` | A `LogScope`. |

### Your own socket

`RpcHttp2CallerTransport.viaSocket` wraps a socket you already opened, for
example a `SecureSocket` with certificate pinning or a custom tunnel. You own
the socket. `reconnect()` is not supported on such a transport: it reports
`degraded` and leaves the live connection alone.

```dart
import 'dart:io';

import 'package:rpc_dart_http2/rpc_dart_http2.dart';

Future<RpcHttp2CallerTransport> pinnedTransport(SecurityContext context) async {
  final socket = await SecureSocket.connect(
    'api.example.com',
    443,
    context: context,
    supportedProtocols: ['h2'],
  );
  return RpcHttp2CallerTransport.viaSocket(
    socket,
    host: 'api.example.com',
    port: 443,
  );
}
```

`scheme` defaults to `https`; pass `scheme: 'http'` for a plaintext socket.

### Reconnecting

The transport does not reconnect by itself. When the connection drops, calls
fail with `UNAVAILABLE` and `health()` reports it. Call `reconnect()` to open a
new connection on the same transport:

```dart
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

Future<void> recover(RpcHttp2CallerTransport transport) async {
  final status = await transport.reconnect();
  if (status.isHealthy) print('reconnected');
}
```

Calls still in flight on the old connection fail with `UNAVAILABLE`. Stream ids
continue across the reconnect; they are not reset, so a call from the old
connection can never share an id with a new one. Concurrent `reconnect()` calls
join the same attempt.

A server that sends GOAWAY is draining. New calls on that connection fail with
`UNAVAILABLE`, which a retry interceptor can act on after `reconnect()`.

## Server

`RpcHttp2Server` accepts connections and gives each one its own
`RpcResponderEndpoint`. The quick form registers the same contract instances on
every connection:

```dart
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

Future<RpcHttp2Server> serve() async {
  final server = RpcHttp2Server.createWithContracts(
    host: '0.0.0.0',
    port: 8080,
    contracts: [GreeterResponder()],
  );
  await server.start();
  return server;
}
```

Use the main constructor for per-connection setup: fresh contract instances,
interceptors, or observability hooks.

```dart
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

final server = RpcHttp2Server(
  host: '0.0.0.0',
  port: 8080,
  onEndpointCreated: (endpoint) {
    endpoint.registerServiceContract(GreeterResponder());
  },
  onConnectionOpened: (socket) => print('open ${socket.remoteAddress}'),
  onConnectionClosed: (socket) => print('closed ${socket.remoteAddress}'),
  onConnectionError: (error, stackTrace) => print('error $error'),
);
```

An exception thrown from an observability hook is logged. One thrown from
`onEndpointCreated` drops that connection. Neither stops the server.

`host` defaults to `'localhost'`, which is reachable only from the same
machine. Bind `'0.0.0.0'` to accept remote clients. Pass `port: 0` to bind any
free port and read it from `server.port` after `start()`.

`transportWrapper` wraps each connection's transport before the endpoint sees
it, for example to add an encryption layer:

```dart
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

final wrapped = RpcHttp2Server(
  port: 8080,
  transportWrapper: (inner, socket) => EncryptedTransport(inner),
  onEndpointCreated: (endpoint) {
    endpoint.registerServiceContract(GreeterResponder());
  },
);
```

`EncryptedTransport` is your own `IRpcTransport`. If it does not forward the
security policy or flow control, the server keeps the inner transport's.

### Stopping

`stop()` closes every connection at once; calls in flight end.
`stop(drainTimeout: ...)` stops accepting, sends GOAWAY on every connection so
peers open no new streams, waits up to that long for running calls to finish,
then closes.

```dart
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

Future<void> shutdown(RpcHttp2Server server) =>
    server.stop(drainTimeout: const Duration(seconds: 10));
```

### TLS

Pass a `SecurityContext` and the server binds a TLS socket that advertises ALPN
`h2`. Without one it serves plaintext h2c.

```dart
import 'dart:io';

import 'package:rpc_dart_http2/rpc_dart_http2.dart';

Future<RpcHttp2Server> serveTls() async {
  final context = SecurityContext()
    ..useCertificateChain('server.crt')
    ..usePrivateKey('server.key');
  final server = RpcHttp2Server(
    host: '0.0.0.0',
    port: 8443,
    securityContext: context,
    onEndpointCreated: (endpoint) {
      endpoint.registerServiceContract(GreeterResponder());
    },
  );
  await server.start();
  return server;
}
```

`server.isSecure` reports which mode it runs in.

### Your own listener

If the listener already exists, build the responder transport per socket with
`RpcHttp2ResponderTransport.overStreams`. Prefer it over the constructor that
takes a ready `http2.ServerTransportConnection`: only `overStreams` bounds
header blocks and advertises `maxActiveStreams` to the peer.

```dart
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

Future<void> serveOn(SecurityContext context) async {
  final listener = await SecureServerSocket.bind(
    '0.0.0.0',
    8443,
    context,
    supportedProtocols: const ['h2'],
  );
  listener.listen((socket) {
    final transport = RpcHttp2ResponderTransport.overStreams(
      incoming: socket,
      outgoing: socket,
      destroy: socket.destroy,
    );
    final endpoint = RpcResponderEndpoint(transport: transport)
      ..registerServiceContract(GreeterResponder())
      ..start();
    socket.done.whenComplete(endpoint.close).ignore();
  });
}
```

This path has no preface timeout and no keepalive; `RpcHttp2Server` adds both.

### Server options

| Option | Default | Meaning |
| --- | --- | --- |
| `host` | `'localhost'` | Bind address. |
| `port` | required | `0` picks a free port. |
| `securityPolicy` | `const RpcSecurityPolicy()` | Per-connection limits; see [Limits](#limits). |
| `securityContext` | `null` | TLS (h2) when set, plaintext (h2c) otherwise. |
| `pingInterval` | 30 s | PING on idle connections. The only bound on a peer that went silent after the handshake. `null` disables it. |
| `pingTimeout` | `pingInterval` | Wait for the PING ACK before the socket is destroyed. |
| `prefaceTimeout` | 30 s | Drops a socket that sends no HTTP/2 preface in time: port scanners, HTTP/1.1 clients. `null` disables it; do so if a load balancer opens connections long before it uses them. |
| `onEndpointCreated` | `null` | Register contracts on each connection's endpoint. |
| `onConnectionOpened`, `onConnectionClosed`, `onConnectionError` | `null` | Observability hooks. |
| `transportWrapper` | `null` | Wraps each connection's transport. |
| `logger` | `null` | A `LogScope` for the server and its transports. |
| `logController` | `null` | Passed to every responder endpoint. |

`createWithContracts` takes `host`, `port`, `contracts`, `securityPolicy`,
`securityContext` and `logger`, and uses the defaults for the rest.

## Limits

The server's `securityPolicy` applies per connection. On top of what the
endpoint enforces:

- `maxActiveStreams` is advertised to the peer as `SETTINGS_MAX_CONCURRENT_STREAMS`
  and enforced.
- `maxMetadataBytes` also bounds a HEADERS block with its CONTINUATION frames.
  A peer that exceeds it has its socket destroyed, and `onConnectionError`
  receives a `RESOURCE_EXHAUSTED` status.
- `flowControlWindowBytes` bounds request payload that a handler has received
  but not consumed. Past it the call is refused, not the connection.
- Requests that are not `POST` are refused.

The caller's `policy` bounds what a response may cost, and `maxActiveStreams`
caps concurrent calls on the connection. A response the consumer has stopped
reading fails the call past `flowControlWindowBytes`, each message counting its
payload plus 128 bytes.

## gRPC interop

Requests carry the gRPC-over-HTTP/2 headers:

```
:method       POST
:path         /{Service}/{method}
:scheme       https | http
:authority    {host}
te            trailers
content-type  application/grpc
user-agent    rpc-dart/1.0.0   (unless the call sets its own)
```

Responses send `grpc-status` and `grpc-message` in trailers, or in a single
Trailers-Only HEADERS frame when the call fails before any data. Deadlines
travel as `grpc-timeout`. Cancellation is `RST_STREAM`, and flow control is
HTTP/2's own `WINDOW_UPDATE`.

What this means for real gRPC peers:

- An `RpcHttp2Server` can be called from any gRPC client, and
  `RpcHttp2CallerTransport` can call any gRPC server, when the service and
  method names match and both sides use the same payload encoding. Foreign
  peers almost always use protobuf, so give such contracts a protobuf codec
  (`RpcBinaryCodec` over `protoc`-generated messages), not the default.
- `grpcurl` and similar tools need server reflection to discover services:
  register `ServerReflectionContract` from `rpc_dart_grpc_reflection`.
- rpc_dart adds a few metadata headers of its own (`x-trace-id`,
  `x-request-id`, `x-route-service`). gRPC peers ignore them, and a proxy that
  strips them costs only tracing. The `x-rpc-*` flow-control headers that
  rpc_dart uses on other transports are not used over HTTP/2.
- A non-200 `:status`, such as a proxy's error page, is mapped to a gRPC status
  with `grpcStatusFromHttpStatus` from `rpc_dart`. A `200` without a gRPC
  `content-type` fails as `INTERNAL`.

## Pitfalls

- `host` defaults to `'localhost'`. A server left on the default is not
  reachable from other machines.
- The client sends no keepalive unless you set `pingInterval`. Behind NAT or a
  load balancer a dead connection is otherwise noticed only when a call times
  out.
- `createWithContracts` shares one instance of each contract across all
  connections. Keep per-connection state out of those contracts, or use
  `onEndpointCreated` to build new ones.
- A transport from `viaSocket` cannot reconnect. Build a new one.
- Without `drainTimeout`, `stop()` cuts calls in flight.

[`rpc_dart`]: https://pub.dev/packages/rpc_dart
[`rpc_dart_http`]: https://pub.dev/packages/rpc_dart_http
[`rpc_dart_websocket`]: https://pub.dev/packages/rpc_dart_websocket
