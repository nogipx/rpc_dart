<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_http

HTTP/1.1 caller and responder transports for [`rpc_dart`].

Each RPC call is one HTTP POST and one response. Use it when the network path
only tolerates plain HTTP: proxies and gateways that terminate HTTP/1.1, CDNs,
or environments where HTTP/2 or a WebSocket upgrade is not available.

**Unary methods only.** HTTP/1.1 cannot stream frames in both directions inside
one request, so streaming methods do not fail here; they degrade:

- A finite stream is buffered whole. Nothing arrives until the handler
  finishes, then everything at once. Client-streaming and bidirectional calls
  round-trip the same way.
- The whole stream must fit in one body. It is bounded by
  `RpcSecurityPolicy.maxBufferedBytes` and, because the body reaches the parser
  as one chunk, by `maxMessagesPerChunk`. Past either the call fails with
  `RESOURCE_EXHAUSTED`.
- An unbounded stream never returns, because the response cannot start until
  the handler ends. Give it a deadline if it has to run here.

For streaming use [`rpc_dart_http2`], [`rpc_dart_websocket`] or
[`rpc_dart_isolate`].

Contracts, endpoints, errors and `RpcSecurityPolicy` belong to the core package;
see [`rpc_dart`]. This README covers only what is specific to this transport.

## Platforms

- `RpcHttpCallerTransport` uses only `package:http`. It runs on the VM,
  Flutter, dart2js and Wasm, so a browser or mobile app can embed it.
- `RpcHttpResponderTransport`, `RpcHttpServer` and `RpcHttpCorsPolicy` are
  built on `package:shelf` and `dart:io`. They run on the VM only.

## Install

```yaml
dependencies:
  rpc_dart: ^6.3.0
  rpc_dart_http: ^0.4.0
```

## Client

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';

Future<void> callServer() async {
  final transport = RpcHttpCallerTransport(baseUrl: 'https://api.example.com');
  final endpoint = RpcCallerEndpoint(transport: transport);

  final reply = await GreeterCaller(endpoint).hello(
    const RpcString('http'),
    context: RpcContext.withTimeout(const Duration(seconds: 5)),
  );
  print(reply.value);

  await endpoint.close();
}
```

`GreeterCaller` and `GreeterResponder` stand for your own contracts.

`baseUrl` may carry a path prefix (`https://host/rpc`); a trailing slash is
ignored. A call posts to `{baseUrl}/{Service}/{method}`.

The transport has no timeout of its own. Bound calls with a deadline in the
`RpcContext`; it travels as `grpc-timeout`. Cancelling a call aborts its HTTP
request. `reconnect()` is a no-op that reports healthy, because there is no
connection to restore.

### Custom HTTP client

Pass an `http.Client` to configure TLS, proxies or connection reuse. To trust a
private CA on the VM, wrap a `dart:io` `HttpClient`:

```dart
import 'dart:io';

import 'package:http/io_client.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';

RpcHttpCallerTransport privateCaTransport() {
  final context = SecurityContext(withTrustedRoots: true)
    ..setTrustedCertificates('/etc/ssl/private-ca.pem');
  return RpcHttpCallerTransport(
    baseUrl: 'https://internal.example.com',
    httpClient: IOClient(HttpClient(context: context)),
  );
}
```

Do not set `badCertificateCallback` to return `true`. It accepts every
certificate, including an attacker's.

A client you pass in stays yours: `close()` closes only a client the transport
created itself. Close your own client when you are done with it.

## Server

`RpcHttpServer` starts in two phases, so that a DI container can be filled
between them. `start()` creates the transport. `afterModulesStart()` creates
the endpoint, calls `onEndpointCreated`, and binds the port. Without the second
call nothing listens.

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';

Future<RpcHttpServer> serve() async {
  final server = RpcHttpServer(
    host: '0.0.0.0',
    port: 8080,
    onEndpointCreated: (endpoint) {
      endpoint.registerServiceContract(GreeterResponder());
    },
  );
  await server.start();
  await server.afterModulesStart();
  print('Listening on ${server.actualPort}');
  return server;
}
```

With `RpcApp.server` from `rpc_dart_framework`, call
`server.afterModulesStart()` from its `afterModulesStart` callback.
`afterModulesStart(preamble: handler)` mounts another shelf handler, such as a
webhook, in front of the RPC handler.

All requests share one `RpcResponderEndpoint`. Pass `port: 0` to bind any free
port and read it from `actualPort`.

`stop()` answers requests still in flight with `UNAVAILABLE`.
`stop(drainTimeout: ...)` stops accepting, waits up to that long for in-flight
requests to finish, then closes.

### Mounting on your own shelf pipeline

`RpcHttpResponderTransport.handler` is a shelf `Handler`. Mount it on any shelf
server or router. The method path is read relative to the mount point.

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> serveWithShelf() async {
  final transport = RpcHttpResponderTransport();
  RpcResponderEndpoint(transport: transport)
    ..registerServiceContract(GreeterResponder())
    ..start();
  await shelf_io.serve(transport.handler, '0.0.0.0', 8080);
}
```

### TLS

`RpcHttpServer` serves plain HTTP. Terminate TLS in front of it, or mount the
responder handler on a TLS shelf server:

```dart
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

Future<void> serveTls() async {
  final context = SecurityContext()
    ..useCertificateChain('server.crt')
    ..usePrivateKey('server.key');
  final transport = RpcHttpResponderTransport();
  RpcResponderEndpoint(transport: transport)
    ..registerServiceContract(GreeterResponder())
    ..start();
  await shelf_io.serve(
    transport.handler,
    '0.0.0.0',
    8443,
    securityContext: context,
  );
}
```

### CORS

Browser callers need a `RpcHttpCorsPolicy`. Without one, an `OPTIONS`
preflight gets `405` and browsers block cross-origin calls.

```dart
import 'package:rpc_dart_http/rpc_dart_http.dart';

final transport = RpcHttpResponderTransport(
  corsPolicy: RpcHttpCorsPolicy(
    allowedOrigins: ['https://app.example.com'],
    allowedHeaders: ['authorization', 'x-tenant-id'],
    allowCredentials: true,
    preflightMaxAge: const Duration(hours: 1),
  ),
);
```

`RpcHttpServer` takes the same `corsPolicy:` parameter.

| Option | Default | Meaning |
| --- | --- | --- |
| `allowedOrigins` | `[]` | Origins allowed to call. Matched case-insensitively. Empty rejects every cross-origin preflight with `403`. |
| `allowedHeaders` | `['authorization', 'x-requested-with']` | Extra request headers. `content-type`, `grpc-timeout`, `grpc-encoding`, `grpc-accept-encoding`, `x-route-service`, `x-request-id` and `x-trace-id` are always allowed. |
| `extraExposedHeaders` | `[]` | Extra response headers a page may read. `grpc-status`, `grpc-message`, `grpc-status-details-bin`, `grpc-encoding` and `grpc-accept-encoding` are always exposed. |
| `allowCredentials` | `false` | Sends `Access-Control-Allow-Credentials: true`. |
| `preflightMaxAge` | 10 minutes | `Access-Control-Max-Age`; `null` omits it. |

`allowedOrigins: ['*']` admits any origin and logs a warning once. It cannot be
combined with `allowCredentials: true`; the constructor throws, because browsers
reject that pair. Rejections (`415`, `413`, `503`, ...) carry the CORS headers
too, so a page sees the real status instead of an opaque CORS error.

## Server options

`RpcHttpResponderTransport` and `RpcHttpServer` take the same options.

| Option | Default | Meaning |
| --- | --- | --- |
| `securityPolicy` | `const RpcSecurityPolicy()` | Limits on requests; see below. `null` disables this transport's own checks and allows unbounded bodies. |
| `corsPolicy` | `null` | CORS for browser callers. |
| `bodyIdleTimeout` | 30 s | Longest silence while the body arrives, reset by every chunk. A body that keeps arriving is never refused by it. `null` disables it. |
| `bodyReadTimeout` | `null` | Ceiling on the whole body read. It refuses a slow honest upload as readily as a stalled one. |

`bodyReadTimeout` also runs while a client that sent `Expect: 100-continue`
waits for a `100 Continue` that `dart:io` never sends (curl sends this header
for bodies over 1 KiB). Leave it `null` on endpoints such clients reach, or set
it well above the client's fallback delay.

## Limits

The caller's `policy:` bounds what a response may cost: response headers and
the response body (`maxBufferedBytes`, by default derived from
`maxMessageLengthBytes`). It also caps concurrent calls with
`maxActiveStreams`.

The responder checks every request before the handler runs:

| Request | HTTP status | Caller sees |
| --- | --- | --- |
| Not `POST` | `405` with `Allow: POST` | `UNKNOWN` |
| `content-type` not `application/grpc[+subtype]` | `415` | `UNKNOWN` |
| More than `maxActiveStreams` requests in flight | `503` | `UNAVAILABLE` |
| Invalid method path, metadata over its limits | `400` | `INTERNAL` |
| Body over `maxBufferedBytes` | `413` | `RESOURCE_EXHAUSTED` |
| Body stalled past `bodyIdleTimeout`, or past `bodyReadTimeout` | `408` | `UNAVAILABLE` |
| Transport closed | `503` | `UNAVAILABLE` |

The responder's reason text is carried into the caller's `grpc-message`, so the
caller learns which limit it hit.

Policy limits that the endpoint enforces, such as `maxConcurrentHandlers`,
apply as on any other transport.

## Wire format

```
Request:   POST {baseUrl}/{Service}/{method}
           content-type: application/grpc+proto
           metadata as ordinary HTTP headers
           body: gRPC-framed messages (1-byte flag, 4-byte length, payload)

Response:  200 OK
           content-type: application/grpc[+subtype], echoing the request
           grpc-status, grpc-message and all metadata as ordinary HTTP headers
           body: gRPC-framed messages
```

There are no HTTP trailers and no `te: trailers`. Repeated metadata keys are
joined with `,`; a value that must contain a comma belongs in a `-bin` key.

This is gRPC-shaped, not gRPC over HTTP/1.1. Real gRPC peers require HTTP/2;
use [`rpc_dart_http2`] to talk to them.

### How the caller reports failures

| Outcome | Status |
| --- | --- |
| Non-200 response | Mapped by `grpcStatusFromHttpStatus` from `rpc_dart`: `400` INTERNAL, `401` UNAUTHENTICATED, `403` PERMISSION_DENIED, `404` UNIMPLEMENTED, `408` UNAVAILABLE, `413` RESOURCE_EXHAUSTED, `429`/`502`/`503`/`504` UNAVAILABLE, `499` CANCELLED, anything else UNKNOWN. The message names the status, the path and the start of the body. |
| `200` with a non-gRPC `content-type` (a proxy's HTML page) | INTERNAL |
| Connection refused or reset, failed TLS handshake | UNAVAILABLE |
| Response body over the caller's limit | RESOURCE_EXHAUSTED |
| Transport closed during the call | UNAVAILABLE |

## Pitfalls

- `RpcHttpServer.start()` alone does not listen. Call `afterModulesStart()`.
- Streaming methods buffer silently. See the top of this file.
- `bodyReadTimeout` refuses slow honest uploads and `Expect: 100-continue`
  clients. Prefer `bodyIdleTimeout` for stalled clients.
- A browser caller needs a `corsPolicy` with its origin listed.
- An `http.Client` you inject is not closed by the transport.

[`rpc_dart`]: https://pub.dev/packages/rpc_dart
[`rpc_dart_http2`]: https://pub.dev/packages/rpc_dart_http2
[`rpc_dart_websocket`]: https://pub.dev/packages/rpc_dart_websocket
[`rpc_dart_isolate`]: https://pub.dev/packages/rpc_dart_isolate
