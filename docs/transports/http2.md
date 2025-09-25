# HTTP/2 transport

HTTP/2 transports speak the same gRPC wire format that traditional gRPC clients
expect. They keep a single TCP connection open while multiplexing every RPC
stream, so once the caller and responder endpoints are wired up you can reuse
all of the core primitives—unary calls, server streams, client streams, and
bidirectional flows—without any extra adapters.

## When to choose HTTP/2

- **Interop with gRPC** – connect RPC Dart services to existing gRPC
  infrastructure, tooling, and contracts without a protocol translation layer.
- **High fan-out service calls** – multiplex many concurrent requests over one
  socket instead of managing a pool of HTTP/1.1 clients.
- **Service mesh friendly** – HTTP/2 is supported by Envoy, Istio, and most
  service meshes, so transports can inherit routing, tracing, and TLS policies
  from the mesh.

## Client setup

Create a caller-side transport with `RpcHttp2CallerTransport.connect` and pass it
into a `RpcCallerEndpoint`:

```dart
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

Future<void> main() async {
  final transport = await RpcHttp2CallerTransport.connect(
    host: 'localhost',
    port: 8765,
    logger: RpcLogger('Http2Client'),
  );

  final endpoint = RpcCallerEndpoint(
    transport: transport,
    debugLabel: 'demo-http2-client',
  );

  final response = await endpoint.unaryRequest<RpcString, RpcString>(
    serviceName: 'DemoService',
    methodName: 'Echo',
    requestCodec: RpcString.codec,
    responseCodec: RpcString.codec,
    request: RpcString('Hello over HTTP/2!'),
  );

  print('Server replied: ${response.value}');

  await transport.close();
}
```

Use `RpcHttp2CallerTransport.secureConnect` to negotiate TLS and HTTP/2 ALPN in
one call:

```dart
final transport = await RpcHttp2CallerTransport.secureConnect(
  host: 'api.example.com',
  port: 443,
  logger: RpcLogger('Http2Client'),
);
```

Caller transports expose the standard diagnostics from `IRpcTransport`.
`transport.health()` returns a `RpcHealthStatus` snapshot and
`transport.reconnect()` re-establishes the underlying HTTP/2 connection using the
stored connection factory.

## Running a server

For most services `RpcHttp2Server.createWithContracts` provides the quickest
setup. It binds a TCP socket, upgrades incoming connections to HTTP/2, and
creates one `RpcResponderEndpoint` per client connection:

```dart
final server = RpcHttp2Server.createWithContracts(
  port: 8765,
  host: '0.0.0.0',
  logger: RpcLogger('Http2Server'),
  contracts: [
    DemoServiceContract(),
  ],
);

await server.start();

// ... later during shutdown
await server.stop();
```

Use the `RpcHttp2Server` constructor directly when you need hooks for lifecycle
observability. The `onEndpointCreated`, `onConnectionOpened`, and
`onConnectionClosed` callbacks let you attach metrics, register additional
contracts, or apply middleware at runtime.

### Example responder contract

```dart
class DemoServiceContract extends RpcResponderContract {
  DemoServiceContract() : super('DemoService');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: _echo,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'GetStream',
      handler: _getStream,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Chat',
      handler: _chat,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _echo(RpcString request, {RpcContext? context}) async {
    return RpcString('echo: ${request.value}');
  }

  Stream<RpcString> _getStream(
    RpcString request, {
    RpcContext? context,
  }) async* {
    for (var i = 0; i < 3; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      yield RpcString('${request.value} #$i');
    }
  }

  Stream<RpcString> _chat(
    Stream<RpcString> requests, {
    RpcContext? context,
  }) async* {
    await for (final message in requests) {
      yield RpcString('received: ${message.value}');
    }
  }
}
```

## Handling custom listeners and TLS

If you already have a listener (for example behind a reverse proxy, inside a
service mesh sidecar, or using `SecureServerSocket.bind`) you can instantiate
`RpcHttp2ResponderTransport` manually:

```dart
import 'dart:io';
import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';

Future<void> serveOverTls(SecurityContext context) async {
  final secureSocket = await SecureServerSocket.bind(
    '0.0.0.0',
    8443,
    context,
    supportedProtocols: const ['h2'],
  );

  secureSocket.listen((SecureSocket socket) {
    final connection = http2.ServerTransportConnection.viaSocket(socket);
    final transport = RpcHttp2ResponderTransport(
      connection: connection,
      logger: RpcLogger('Http2Responder'),
    );

    final endpoint = RpcResponderEndpoint(transport: transport);
    endpoint.registerServiceContract(DemoServiceContract());
    endpoint.start();
  });
}
```

Every responder endpoint created this way still participates in the same
`IRpcTransport` contract, so middleware, interceptors, and health checks behave
identically across transports.

## Streaming flows

HTTP/2 transports deliver all four RPC styles. The caller API is the same as
with in-memory or WebSocket transports:

```dart
final endpoint = RpcCallerEndpoint(transport: transport);

// Server streaming
final updates = endpoint.serverStream<RpcString, RpcString>(
  serviceName: 'DemoService',
  methodName: 'GetStream',
  requestCodec: RpcString.codec,
  responseCodec: RpcString.codec,
  request: RpcString('stream please'),
);
await for (final update in updates) {
  print('update: ${update.value}');
}

// Bidirectional streaming
final responses = endpoint.bidirectionalStream<RpcString, RpcString>(
  serviceName: 'DemoService',
  methodName: 'Chat',
  requestCodec: RpcString.codec,
  responseCodec: RpcString.codec,
  requests: Stream.periodic(
    const Duration(milliseconds: 250),
    (i) => RpcString('message #$i'),
  ).take(3),
);
await for (final reply in responses) {
  print('reply: ${reply.value}');
}
```

## Diagnostics and resiliency

Both caller and responder transports implement `IRpcTransport` so you can:

- Inspect live state with `transport.health()` and feed it into your monitoring
  pipeline.
- Call `transport.reconnect()` on the client when the socket is lost. Server
  transports report that manual reconnect is not supported, which signals the
  endpoint to close gracefully.
- Close transports explicitly with `transport.close()` when the endpoint shuts
  down to release HTTP/2 streams cleanly.

Pair these hooks with `RpcEndpoint.health()` and `RpcEndpointPingProtocol` from
`rpc_dart` to build readiness and liveness checks for your services.

## gRPC interoperability

RPC Dart already encodes requests with gRPC headers and framing, so any gRPC
client can talk to a responder exposed through `RpcHttp2Server`:

```bash
grpcurl -plaintext -d '{"a": 10, "b": 5}' \
  localhost:8765 DemoService/Add
```

Likewise, caller transports can target existing gRPC servers as long as the
service names and method names match the contracts you generate from their
protobuf definitions.
