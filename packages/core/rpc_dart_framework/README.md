<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_framework

Application framework for `rpc_dart`. Provides module lifecycle management, dependency injection, environment configuration, rate limiting, reconnecting client transport, and an in-process test harness.

---

## Table of contents

- [Overview](#overview)
- [RpcApp](#rpcapp)
- [Modules](#modules)
  - [RpcModule](#rpcmodule)
  - [RpcServerModule](#rpcservermodule)
  - [RpcIsolateModule](#rpcisolatemodule)
  - [Dependency ordering](#dependency-ordering)
- [RpcContainer — dependency injection](#rpccontainer--dependency-injection)
- [RpcEnvConfig — environment variables](#rpcenvconfig--environment-variables)
- [RpcAppConfig — hooks and timeouts](#rpcappconfig--hooks-and-timeouts)
- [RpcRateLimiter](#rpcratelimiter)
- [RpcClientConnection](#rpcclientconnection)
- [Health](#health)
- [Testing](#testing)

---

## Overview

The framework wraps the low-level `rpc_dart` primitives (`RpcResponderEndpoint`, `RpcCallerEndpoint`, transports) behind a structured lifecycle:

```
modules → DI container → transport server → connections → contracts
```

Each module declares what it needs (`dependencies`), what it provides (`configure`, `onStart`), and how to clean up (`onStop`). The framework performs a topological sort, starts modules in dependency order, and stops them in reverse.

---

## RpcApp

The single entry point for server applications.

```dart
await RpcApp.server(
  modules: [
    PostgresModule(),
    MinioModule(),
    UserModule(),   // depends on PostgresModule
  ],
  server: (onEndpoint) => RpcWebSocketServer(
    connections: wsModule.connections,
    onEndpointCreated: onEndpoint,
  ),
  interceptors: [authInterceptor, rateLimiter],
  config: RpcAppConfig(
    env: Platform.environment,
    logger: RpcLogger('my-service'),
    onError: (e, st, service, method) => logger.error('$service/$method', e),
    onCall:  (event) => metrics.record(event),
  ),
).run(); // blocks until SIGTERM / SIGINT, then stops cleanly
```

`run()` handles OS signals. Use `start()` / `stop()` for manual control (e.g. in tests).

---

## Modules

### RpcModule

Infrastructure module: opens connections, registers shared services. No RPC contracts.

```dart
class PostgresModule extends RpcModule {
  @override
  String get name => 'Postgres';

  @override
  List<Type> get dependencies => []; // declared module types, not instances

  // Sync — read env, register config objects.
  @override
  void configureWithEnv(RpcContainer c, RpcEnvConfig env) {
    c.registerSingleton<DbConfig>(DbConfig(
      host: env['PG_HOST'] ?? 'localhost',
      port: env.getInt('PG_PORT') ?? 5432,
    ));
  }

  Pool? _pool;

  // Async — open connections, register heavy objects.
  @override
  Future<void> onStart(RpcContainer c) async {
    final cfg = c.get<DbConfig>();
    _pool = await Pool.connect(cfg);
    c.registerSingleton<IDataClient>(DataClient(_pool!));
  }

  @override
  Future<void> onStop() async => _pool?.close();

  // Return null to skip health reporting for this module.
  @override
  Future<RpcHealthStatus?> checkHealth() async {
    try {
      await _pool?.execute('SELECT 1');
      return RpcHealthStatus.healthy(component: name, message: 'ok');
    } catch (e) {
      return RpcHealthStatus.unhealthy(component: name, message: '$e');
    }
  }
}
```

### RpcServerModule

Registers RPC contracts on incoming connections. `buildContracts` is called **per connection** — return fresh instances. Shared state lives in DI singletons registered by infrastructure modules.

```dart
class UserModule extends RpcServerModule {
  @override
  String get name => 'UserModule';

  @override
  List<Type> get dependencies => [PostgresModule]; // starts after Postgres

  @override
  List<RpcResponderContract> buildContracts(RpcContainer c) {
    return [
      UserResponder(
        client: c.get<IDataClient>(), // shared singleton — OK
        // do NOT store per-connection state in the module class itself
      ),
    ];
  }
}
```

### RpcIsolateModule

Runs contract handlers in a dedicated Dart isolate. Use for CPU-intensive work (encryption, image processing, heavy computation) that would block the main event loop.

```dart
// 1. Worker entrypoint — MUST be a top-level function (Isolate.spawn requirement).
void hashingWorker(IRpcTransport transport, Map<String, dynamic> params) {
  final endpoint = RpcResponderEndpoint(transport: transport);
  endpoint.registerServiceContract(HashingResponderContract());
  endpoint.start();
}

// 2. Module on the main isolate — buildProxyContracts returns contracts whose
//    handlers forward every call through the isolate transport to the worker.
class HashingModule extends RpcIsolateModule {
  @override
  String get name => 'HashingModule';

  @override
  RpcIsolateEntrypoint get workerEntrypoint => hashingWorker;

  @override
  Map<String, dynamic> get isolateParams => const {}; // transferable values only

  @override
  List<RpcResponderContract> buildProxyContracts(RpcCallerEndpoint caller) {
    return [HashingProxyContract(caller)]; // forwards to worker via RPC-over-isolate
  }
}
```

**How requests flow:**

```
Client ──network──► RpcResponderEndpoint (main isolate)
                          │ proxy contract
                    RpcCallerEndpoint ──IsolateTransport──► RpcResponderEndpoint (worker)
                                                                  │ real handler
                                                               result
```

The isolate transport uses `SendPort` / `ReceivePort` internally and runs the same protocol as network transports — CBOR-framed messages over stream IDs. The worker isolate has no access to the main isolate's `RpcContainer`; pass any needed config through `isolateParams`.

### Dependency ordering

`dependencies` contains **Type** references, not instances:

```dart
@override
List<Type> get dependencies => [PostgresModule, RedisModule];
```

The framework topologically sorts all modules and guarantees:
- Start order respects dependencies (dependencies first).
- Stop order is reversed (dependents stop before their dependencies).
- Circular dependencies throw `StateError` at startup.

---

## RpcContainer — dependency injection

Type-keyed singleton and factory registry.

```dart
// Registration
c.registerSingleton<IDataClient>(DataClient(pool));
c.registerFactory<MyService>((container) => MyService(container.get<IDataClient>()));

// Resolution
final client = c.get<IDataClient>();       // throws if absent
final client = c.tryGet<IDataClient>();    // null if absent
final exists  = c.has<IDataClient>();
```

Register singletons in `configure` / `configureWithEnv` for sync objects, in `onStart` for objects requiring async initialisation. Factories are resolved lazily on first `get<T>()`.

---

## RpcEnvConfig — environment variables

Typed, null-safe access to a `Map<String, String>`.

```dart
env.require('DATABASE_URL')          // String — throws if missing
env['OPTIONAL_KEY']                  // String?
env.getInt('PORT') ?? 8080
env.getBool('DEBUG')                 // true only if value == 'true'
env.getDuration('TIMEOUT')           // parses '30s', '5m', '2h', '100ms'
env.getList('ALLOWED_ORIGINS')       // splits on comma, trims whitespace
```

Pass the env map via `RpcAppConfig.env`:

```dart
RpcAppConfig(env: Platform.environment)
// or override specific values in tests:
RpcAppConfig(env: {'PORT': '9090', 'DEBUG': 'true'})
```

---

## RpcAppConfig — hooks and timeouts

```dart
RpcAppConfig(
  env: Platform.environment,
  logger: RpcLogger('service-name'),
  shutdownTimeout: Duration(seconds: 30), // per-module onStop timeout
  drainTimeout:    Duration(seconds: 10), // wait for in-flight streams to finish

  // Called for every unhandled exception in any contract handler.
  onError: (error, stackTrace, serviceName, methodName) {
    Sentry.captureException(error, stackTrace: stackTrace);
  },

  // Called after every completed RPC call (success or failure).
  onCall: (RpcCallEvent event) {
    metrics.histogram('rpc.duration', event.duration.inMilliseconds,
        tags: {'service': event.serviceName, 'method': event.methodName});
  },
)
```

`onError` and `onCall` are automatically wired as interceptors covering all four call types (unary, server-stream, client-stream, bidirectional).

---

## RpcRateLimiter

`IRpcInterceptor` that enforces request-rate limits. Two algorithms:

| Algorithm | API | Characteristics |
|---|---|---|
| Sliding window log | `RateLimit.slidingWindow(max, window)` | Exact, O(n) memory per key |
| Token bucket | `RateLimit.tokenBucket(max, window, burst?)` | Burst-tolerant, O(1) |

```dart
final limiter = RpcRateLimiter(
  // Single shared counter across all callers.
  global: RateLimit.slidingWindow(max: 10000, window: Duration(seconds: 1)),

  // Per-service shared counter (all callers share one budget).
  perService: {
    'BlobService': RateLimit.tokenBucket(max: 200, window: Duration(seconds: 1), burst: 400),
  },

  // Per-method shared counter.
  perMethod: {
    'UserService/deleteUser': RateLimit.slidingWindow(max: 10, window: Duration(minutes: 1)),
  },

  // Extract a per-caller key from the request context.
  // When set, perService and perMethod create independent counters per key.
  keyExtractor: (call) =>
      call.context.getValue<String>('userId') ?? 'anon:${call.endpoint.hashCode}',

  // Catch-all: applies per (key, method) for any method not listed in perMethod.
  perKeyFallback: RateLimit.slidingWindow(max: 50, window: Duration(seconds: 1)),
);

// Pass as an interceptor to RpcApp.server or RpcTestApp.
// Always call dispose() on shutdown to cancel the cleanup timer.
rateLimiter.dispose();
```

**Priority chain** (with `keyExtractor`):

```
perMethod[key] → perService[key] → perKeyFallback[key:method] → global (always shared)
```

Without `keyExtractor` all counters are shared (no per-key isolation).

Exceeding a limit throws `RpcRateLimitException` (extends `RpcException`), which the framework propagates to the client as an RPC error.

---

## RpcClientConnection

Reconnecting client transport with observable connection state. Use directly in Flutter/client apps — no module system needed.

```dart
final connection = RpcClientConnection(
  transportFactory: () async {
    final ch = WebSocketChannel.connect(Uri.parse(serverUrl));
    await ch.ready;
    return RpcWebSocketCallerTransport(ch);
  },
  policy: ExponentialBackoffPolicy(
    delays: [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 30)],
  ),
  // Return false to stop reconnecting (session expired, payment required, etc.)
  shouldReconnect: (error) => !error.toString().contains('unauthenticated'),
);

// Create endpoint ONCE — it survives all reconnects transparently.
// In-flight calls on a dropped connection receive errors; new calls
// automatically use the new underlying transport.
final endpoint = RpcCallerEndpoint(transport: connection.transport);
final api = MyCallerContract(endpoint);

// Observe state changes (integrate with BLoC, StreamBuilder, etc.)
connection.state.listen((state) => switch (state) {
  RpcClientOnline()                       => showConnected(),
  RpcClientOffline()                      => showReconnecting(),
  RpcClientConnecting(:final attempt)     => showAttempt(attempt),
  RpcClientDisconnected(:final reason)    => showError(reason),
  RpcClientIdle()                         => {},
});

connection.connect();           // start connecting
connection.forceReconnect();    // drop current transport, reconnect immediately
await connection.disconnect();  // stop reconnecting, stay idle (reusable)
await connection.dispose();     // permanent teardown
```

**States:**

| State | Meaning |
|---|---|
| `RpcClientIdle` | Not started or after `disconnect()` |
| `RpcClientConnecting(attempt)` | Waiting before attempt N (backoff delay) |
| `RpcClientOnline` | Transport ready |
| `RpcClientOffline` | Transport dropped, reconnect loop running |
| `RpcClientDisconnected(reason)` | Terminal — `shouldReconnect` returned false |

**Policies:**

```dart
ExponentialBackoffPolicy(delays: [...]) // cycles through delays, clamps at last
FixedDelayPolicy(Duration(seconds: 5))  // constant delay between attempts
```

---

## Health

`RpcApp.health()` returns an `RpcAppHealth` snapshot:

```dart
final health = await app.health();

health.level;    // RpcAppHealthLevel.healthy | degraded | unhealthy
health.isHealthy;
health.isServing; // healthy or degraded

// Per-module breakdown (only modules that returned non-null from checkHealth())
health.modules;  // Map<String, Map<String, Object?>>

// Active endpoint metrics (openStreams, totalCalls, etc.)
health.endpoints; // List<Map<String, Object?>>

health.toJson(); // ready for an HTTP health-check response body
```

Overall level is derived from the worst module level: any `unhealthy` module → `unhealthy`; any `degraded` → `degraded`; all healthy → `healthy`.

---

## Testing

### RpcTestApp

Runs the full module stack in-process with an `RpcInMemoryTransport` pair — no network required.

```dart
late RpcTestApp app;

setUp(() async {
  app = await RpcTestApp.start(
    modules: [UserModule()],
    interceptors: [authStubInterceptor],
    env: {'DB_URL': 'sqlite::memory:'},
  );
});

tearDown(() => app.dispose());

test('getUser returns correct user', () async {
  final client = UserCallerContract(app.caller);
  final user = await client.getUser(GetUserRequest(id: '1'));
  expect(user.name, 'Alice');
});
```

`RpcTestApp` supports all module types (`RpcServerModule`, `RpcIsolateModule`), `RpcAppConfig` hooks, env overrides, and topological module ordering.

### RpcCallSpy

Records every call passing through an endpoint. Useful for asserting interaction contracts.

```dart
final spy = RpcCallSpy();
// add to RpcTestApp interceptors or RpcApp.server interceptors

spy.calls;                             // List<RpcCallRecord> — all calls
spy.callsFor('UserService/getUser');   // filtered by service/method
spy.reset();
```

### RpcFaultInjector

Injects errors or latency into specific methods. Useful for resilience testing.

```dart
final injector = RpcFaultInjector()
  ..injectError('UserService/getUser', RpcException('forced error'))
  ..injectDelay('BlobService/upload', Duration(seconds: 3));

// Remove injected fault
injector.clearFault('UserService/getUser');
```
