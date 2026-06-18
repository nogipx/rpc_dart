<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# HTTP/2 Transport

`rpc_dart_http2` provides an HTTP/2 transport for native platforms. It supports all four RPC patterns, multiplexes streams over a single TCP connection, and uses gRPC-compatible pseudo-headers — making it interoperable with any gRPC server or client that speaks the wire protocol.

!!! note "Native only"
    `rpc_dart_http2` depends on `dart:io` and does not compile to JS or Wasm. For web clients use [WebSocket](websocket.md) or [HTTP/1.1](http.md).

---

## Installation

```yaml
dependencies:
  rpc_dart_http2: <latest>
```

---

## Server

`RpcHttp2Server` accepts incoming TCP connections, wraps each in `RpcHttp2ResponderTransport`, creates a `RpcResponderEndpoint`, and fires `onEndpointCreated` so you can register contracts.

### Quick setup

```dart
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

final server = RpcHttp2Server.createWithContracts(
  host: '0.0.0.0',
  port: 8080,
  contracts: [CalculatorResponder()],
);

await server.start();

// later
await server.stop();
```

### Manual setup

Use the default constructor when you need per-connection logic — registering contracts based on auth headers, wrapping transports, etc.:

```dart
final server = RpcHttp2Server(
  host: '0.0.0.0',
  port: 8080,
  onEndpointCreated: (endpoint) {
    endpoint.registerServiceContract(CalculatorResponder());
    endpoint.addInterceptor(OtelRpcInterceptor(tracer: tracer));
  },
  onConnectionError: (error, stackTrace) => print('Error: $error'),
  onConnectionOpened: (socket) => print('Connected: ${socket.remoteAddress}'),
  onConnectionClosed: (socket) => print('Closed: ${socket.remoteAddress}'),
);

await server.start();
```

`transportWrapper` lets you wrap every new transport before the endpoint sees it — useful for encryption overlays:

```dart
RpcHttp2Server(
  port: 8080,
  transportWrapper: (inner, socket) => EncryptedTransport(inner),
  onEndpointCreated: (endpoint) {
    endpoint.registerServiceContract(MyResponder());
  },
);
```

---

## Client

```dart
// TLS (production)
final transport = await RpcHttp2CallerTransport.secureConnect(
  host: 'api.example.com',
  port: 443,
);

// Plain TCP (local dev, internal network)
final transport = await RpcHttp2CallerTransport.connect(
  host: 'localhost',
  port: 8080,
);

final caller = CalculatorContractCaller(
  RpcCallerEndpoint(transport: transport),
);

final result = await caller.sum(SumRequest(values: [1, 2, 3]));

await caller.endpoint.close();
```

---

## Reconnection

The caller transport stores a connection factory internally and can reconnect after a drop:

```dart
final status = await transport.reconnect();
if (status.isHealthy) {
  print('Reconnected');
}
```

Stream ID counters reset on reconnect.

---

## Security Policy

Both client and server accept `RpcSecurityPolicy` to limit resource usage:

```dart
RpcHttp2CallerTransport.secureConnect(
  host: 'api.example.com',
  port: 443,
  policy: RpcSecurityPolicy(
    maxActiveStreams: 100,
    maxMessageLengthBytes: 4 * 1024 * 1024,
  ),
);
```

---

## gRPC Compatibility

The transport maps RPC method paths to HTTP/2 pseudo-headers in the gRPC format:

```
:method    = POST
:path      = /ServiceName/MethodName
:scheme    = https
:authority = host
```

A `rpc_dart` server with HTTP/2 transport can be called from any standard gRPC client (Go, Java, Python, etc.) — and vice versa.