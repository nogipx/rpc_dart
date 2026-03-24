# WebSocket Transport

`rpc_dart_websocket` provides a WebSocket transport built on [`package:web_socket_channel`](https://pub.dev/packages/web_socket_channel). It supports all four RPC patterns, compiles to all platforms including JS and Wasm, and is the recommended choice for browser clients that need streaming.

---

## Installation

```yaml
dependencies:
  rpc_dart_websocket: <latest>
```

---

## Client

```dart
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';

final transport = RpcWebSocketCallerTransport.connect(
  Uri.parse('wss://api.example.com/rpc'),
);

final caller = CalculatorContractCaller(
  RpcCallerEndpoint(transport: transport),
);

final result = await caller.sum(SumRequest(values: [1, 2, 3]));

await caller.endpoint.close();
```

### Options

```dart
RpcWebSocketCallerTransport.connect(
  Uri.parse('wss://api.example.com/rpc'),
  protocols: ['rpc-v1'],          // WebSocket sub-protocols
  chunkSizeBytes: 64 * 1024,      // max chunk size for large messages (default 64 KB)
  enableChunking: false,          // enable chunked transfer for large payloads
  policy: RpcSecurityPolicy(...),
);
```

### Reconnection

The caller transport stores a factory that recreates the channel on demand. Call `reconnect()` after a connection drop:

```dart
final status = await transport.reconnect();
if (status.isHealthy) {
  print('Reconnected');
}
```

---

## Server

`RpcWebSocketServer` consumes an external stream of already-upgraded `WebSocketChannel` connections — it has no HTTP server inside. Wire it to whatever HTTP server or framework you use for the upgrade handshake.

### With `shelf_web_socket` (native)

```dart
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final connectionController = StreamController<WebSocketChannel>();

final rpcServer = RpcWebSocketServer.createWithContracts(
  connections: connectionController.stream,
  contracts: [CalculatorResponder()],
);
await rpcServer.start();

final httpServer = await shelf_io.serve(
  webSocketHandler((channel) => connectionController.add(channel)),
  '0.0.0.0',
  8080,
);
```

### Manual setup (per-connection logic)

```dart
final rpcServer = RpcWebSocketServer(
  connections: connectionStream,
  onEndpointCreated: (endpoint) {
    endpoint.registerServiceContract(CalculatorResponder());
    endpoint.addInterceptor(OtelRpcInterceptor(tracer: tracer));
  },
  onConnectionError: (error, _) => print('Error: $error'),
  onConnectionOpened: (channel) => print('Connected'),
  onConnectionClosed: (channel) => print('Disconnected'),
);
```

---

## Wire Format

Each WebSocket binary message starts with a **5-byte frame header**:

```
[streamId : 4 bytes, big-endian uint32]
[flags    : 1 byte]
  bit 0 – endStream
  bit 1 – metadata frame  (payload is CBOR-encoded metadata)
  bit 2 – chunked data    (payload has an 8-byte chunk header)
```

- **Metadata frames** carry method path and headers encoded as CBOR (compact, self-describing).
- **Data frames** carry gRPC-framed bytes (5-byte prefix + payload), reassembled by `RpcMessageParser` if fragmented.
- **Chunked frames** allow sending large messages in pieces when `enableChunking: true`.

Multiple RPC streams are multiplexed over a single WebSocket connection using stream IDs (clients use odd IDs, servers use even IDs).