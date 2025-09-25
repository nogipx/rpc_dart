# Routing & composition

RPC Dart is transport-agnostic. You can start with a single in-memory pair and
scale out to multiple network transports without changing business code. This
guide shows how to route calls across transports and how to compose utilities
such as routers and distributors.

## Routing with `RpcTransportRouter`

`RpcTransportRouter` multiplexes client calls to different transports based on
service name, metadata, or custom predicates.

```dart
final router = RpcTransportRouterBuilder.client()
  .routeCall(
    calledServiceName: 'UserService',
    toTransport: httpTransport,
    priority: 100,
  )
  .routeWhen(
    toTransport: websocketTransport,
    whenCondition: (service, method, context) =>
        service == 'NotificationService' &&
        context?.getHeader('x-realtime') == 'true',
    priority: 200,
    description: 'Real-time notifications via WebSocket',
  )
  .routeWhen(
    toTransport: inMemoryTransport,
    whenCondition: (service, method, context) =>
        context?.getHeader('x-route-service') == 'CacheService',
    priority: 50,
    description: 'Internal cache requests stay in-process',
  )
  .build();

final callerEndpoint = RpcCallerEndpoint(transport: router);
```

Rules are evaluated in order of priority (higher first). The router provisions a
new stream ID on the selected transport and proxies responses back to the
original caller. You can inspect routing decisions through the router's logger
for debugging or auditing.

### Tips for effective routing

- Always send the `RpcContext` through to carry routing headers.
- Use `routeCall` for straightforward service-based rules and `routeWhen` for
  metadata-driven routing.
- Combine routers with `RpcTransportRouterBuilder.logger` to surface decisions in
  structured logs.
- Each underlying transport must be **client-side** (uses odd stream IDs). The
  builder validates this automatically.

## Composing responders

A single `RpcResponderEndpoint` can host multiple service contracts. Pair it
with routers to expose a mix of local and remote services:

```dart
final responder = RpcResponderEndpoint(
  transport: combinedServerTransport,
  debugLabel: 'GatewayResponder',
)
  ..registerServiceContract(UserResponder())
  ..registerServiceContract(PaymentResponder())
  ..start();
```

When combined with `RpcTransportRouter` on the caller side you get a clean
hub-and-spoke architecture without centralising business logic.

## Broadcasting with `StreamDistributor`

`StreamDistributor` acts as a message broker for long-lived server streams. You
can expose it through an RPC method while reusing the same infrastructure for
internal subscribers.

```dart
final distributor = StreamDistributor<RpcString>();

class NotificationResponder extends RpcResponderContract {
  NotificationResponder() : super('Notifications');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Subscribe',
      handler: _subscribe,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  void publish(RpcString notification) {
    distributor.publish(notification);
  }

  Stream<RpcString> _subscribe(
    RpcString request, {
    RpcContext? context,
  }) {
    return distributor.getOrCreateClientStream(request.value);
  }
}
```

## Hybrid deployment example

1. **In-memory transport** for colocated services (zero-copy speed).
2. **HTTP/2 transport** for public APIs.
3. **WebSocket transport** for real-time notifications.
4. **Transport router** to direct requests based on service type and tenant tier.

This topology enables graceful migration: start in-memory for development, plug
in additional transports as you scale, and keep the same contracts and handlers
throughout.

## Observability considerations

- Call `router.health()` to inspect the state of each underlying transport.
- Register middleware on caller endpoints to tag requests with routing decisions
  (for example `x-routed-by: websocket`).
- Combine `StreamDistributor.metrics` (total/current streams, total messages,
  average message size) with transport diagnostics to monitor fan out and
  subscriber churn.

With routing and composition primitives you can evolve system architecture
without rewriting the RPC layer, making RPC Dart a long-term foundation for your
service mesh.
