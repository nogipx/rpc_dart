<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_http

HTTP/1.1 caller and responder transports for `rpc_dart`.

Each RPC call is one HTTP request/response pair, which means **unary methods
only** — HTTP/1.1 has no multiplexing and no way to stream frames in both
directions. For streaming use [`rpc_dart_http2`], [`rpc_dart_websocket`] or
[`rpc_dart_isolate`].

Use this transport when the network path only tolerates plain HTTP: proxies and
gateways that terminate HTTP/1.1, CDNs, or environments where an HTTP/2 or
WebSocket upgrade is not available.

The caller is web-safe — it imports only `package:http`, so it compiles to
dart2js/Wasm and is what a Flutter Web or mobile app embeds. The responder and
`RpcHttpServer` are built on `package:shelf` / `dart:io` and are VM-only.

- `RpcHttpCallerTransport` — client transport; takes a `baseUrl` and an
  optional `http.Client` (pass your own for custom TLS, proxies or retries).
- `RpcHttpResponderTransport` — exposes a shelf `Handler` you mount on any
  shelf server or router.
- `RpcHttpServer` — a ready-made `IRpcServer` when you do not need your own
  shelf pipeline.
- `RpcHttpCorsPolicy` — CORS for browser callers. Closed by default:
  `allowedOrigins` is `const []`, so cross-origin preflights are rejected until
  you list origins explicitly.

## Usage

Server:

```dart
import 'package:rpc_dart_http/rpc_dart_http.dart';

final server = RpcHttpServer(
  host: '127.0.0.1',
  port: 8080,
  onEndpointCreated: (endpoint) {
    endpoint.registerServiceContract(MyServiceResponder());
  },
);
await server.start();
```

Client:

```dart
final transport = RpcHttpCallerTransport(baseUrl: 'http://127.0.0.1:8080');
final caller = RpcCallerEndpoint(transport: transport);
```

Mounting on an existing shelf pipeline instead of `RpcHttpServer`:

```dart
import 'package:shelf/shelf_io.dart' as shelf_io;

final transport = RpcHttpResponderTransport();
final endpoint = RpcResponderEndpoint(transport: transport)..start();
await shelf_io.serve(transport.handler, '127.0.0.1', 8080);
```

## Limits

`RpcSecurityPolicy` bounds concurrent requests, body size and header size; pass
it to the transport or to `RpcHttpServer`. A body over
`maxMessageLengthBytes` is rejected with `400`. Set `bodyReadTimeout` to bound
how long a slow or stalled client may hold a request open.

The wire format is gRPC-shaped (`application/grpc+proto`, 5-byte length-prefixed
messages, `grpc-status` in the response), but this is not gRPC-over-HTTP/1.1 —
real gRPC peers require HTTP/2.

[`rpc_dart_http2`]: https://pub.dev/packages/rpc_dart_http2
[`rpc_dart_websocket`]: https://pub.dev/packages/rpc_dart_websocket
[`rpc_dart_isolate`]: https://pub.dev/packages/rpc_dart_isolate
