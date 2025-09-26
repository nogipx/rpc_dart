# WebSocket Transport

WebSocket transports keep a single TCP connection open while multiplexing many
RPC calls. They are ideal for real-time dashboards, collaborative apps, and
scenarios where the client needs to push updates back to the server without
re-establishing a connection for every request.

## When to use WebSocket

- **Bidirectional updates** – UI clients can send commands while receiving
  streaming responses in the same session.
- **Low-latency push** – avoid the overhead of repeatedly negotiating HTTP
  connections when servers need to push data immediately.
- **Firewall friendly** – works when only a single outbound port (such as 443) is
  allowed.

## Client setup

Create a caller-side transport with
`RpcWebSocketCallerTransport.connect` and pass it to a `RpcCallerEndpoint`:

```dart

Future<void> main() async {
  final transport = RpcWebSocketCallerTransport.connect(
Uri.parse('wss://api.example.com/rpc'),
protocols: const ['rpc-dart'],
logger: RpcLogger('WebSocketClient'),
  );

  final caller = RpcCallerEndpoint(transport: transport);
  final chat = ChatCaller(caller);

  final stream = chat.joinRoom('general', 'u-42');
  stream.listen((message) => print('[$message]'));
}
```

`RpcWebSocketCallerTransport.connect` automatically configures a reconnection
factory so you can call `transport.reconnect()` if the socket is dropped.

## Server setup

Use `RpcWebSocketServer` when you already have a source of upgraded
`WebSocketChannel`s (for example via `shelf_web_socket` or a custom `HttpServer`):

```dart
final connections = controller.stream; // Stream<WebSocketChannel>

final server = RpcWebSocketServer.createWithContracts(
  connections: connections,
  port: 8080,
  contracts: [ChatResponder()],
  logger: RpcLogger('WebSocketServer'),
);

await server.start();
```

For lower-level control you can create `RpcWebSocketResponderTransport` directly
from a `WebSocketChannel` and pass it to `RpcResponderEndpoint`.

## Extending the transport

`RpcWebSocketTransportBase` exposes the same hooks as other transports in the
toolkit. You can combine mixins to add buffering or automatic reconnection:

```dart
class ResilientWebSocketTransport extends RpcWebSocketTransportBase
with RpcAutoReconnect, RpcMessageBuffering {
  ResilientWebSocketTransport(WebSocketChannel channel)
  : super(channel, logger: RpcLogger('ResilientWs'));

  @override
  RpcStreamIdManager get idManager => RpcStreamIdManager(isClient: true);

  @override
  bool get isClient => true;
}
```

Use `RpcZeroCopySupport` only for transports that remain inside a single
process; WebSocket transports normally serialise payloads for the wire.

## Diagnostics

All WebSocket transports implement `IRpcTransport`, so you can:

- Call `transport.health()` to obtain `RpcHealthStatus` snapshots.
- Trigger a reconnection with `transport.reconnect()` (client side).
- Close the socket via `transport.close()` when the endpoint shuts down.

Pair these diagnostics with `RpcEndpoint.health()` and `RpcEndpointPingProtocol`
from the core library to build dashboards and alerting around connection health.
