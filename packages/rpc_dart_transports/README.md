<div style="text-align: center;">
  <h1>
    <p>RPC Dart - Transports</p>
  </h1>
</div>

Transport implementations for [RPC Dart](https://pub.dev/packages/rpc_dart). Provides ready transports.

### Core concepts

- Transport — concrete implementation of the IRpcTransport interface.
- Client/Server transports — client-side connectors and server-side handlers.
- Multiplexing — many RPCs over one connection where supported.
- Zero-copy — supported where transport permits in-process object transfer.
- Health monitoring — each transport exposes `health()` snapshots and
  `reconnect()` attempts to simplify diagnostics.

### Supported transports

- WebSocketTransport — bidirectional real-time transport with reconnection and optional multiplexing.
- IsolateTransport — efficient communication between Dart isolates, supports zero-copy for in-process objects.
- Http2Transport — HTTP/2 based transport with gRPC-compatible framing, TLS support and stream multiplexing.
- Http1Transport — unary-only HTTP/1.1 fallback that wraps every request in a POST and adds `x-rpc-integrity` checksums to guarantee payload integrity when a full gRPC stack is unavailable.

### HTTP/1.1 transport (unary only)

When you cannot rely on HTTP/2 but still need RPC calls, `RpcHttp1CallerTransport`/`RpcHttp1Server` send a single unary request per RPC and rely on `x-rpc-integrity` (SHA256 over the framed payload) so both sides can detect tampering. There is no multiplexing or streaming—each call closes the request/response pair as soon as the body is exchanged. Example:

```dart
final server = RpcHttp1Server.createWithContracts(
  host: 'localhost',
  port: 8081,
  contracts: [MyServiceContract()],
);
await server.start();

final transport = RpcHttp1CallerTransport.connect(
  Uri.parse('http://localhost:8081'),
);
final caller = RpcCallerEndpoint(transport: transport);

final response = await caller.unaryRequest<RpcString, RpcString>(
  serviceName: 'MyService',
  methodName: 'Echo',
  requestCodec: RpcString.codec,
  responseCodec: RpcString.codec,
  request: RpcString('hello over HTTP/1.1'),
);
print('Server replied: ${response.value}');
```

#### WebSocket transport notes

- Формат кадра: `[streamId:4][flags:1][gRPC_frame...]`, где gRPC_frame — 5-байтовый префикс gRPC + payload.
- Для больших сообщений можно включить чанкование по WebSocket (`enableChunking: true` в `RpcWebSocketTransportBase` конструкторах в `rpc_dart_transports`). Это режет gRPC frame на куски с дополнительным chunk-header и собирает обратно на приёме.
- По умолчанию чанкование выключено ради обратной совместимости: включайте только если обе стороны используют версию с поддержкой chunked флагов.
