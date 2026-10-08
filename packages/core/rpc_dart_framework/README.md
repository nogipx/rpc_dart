<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_framework

Application framework for `rpc_dart`. Provides module lifecycle management, dependency injection, environment configuration, health aggregation, graceful shutdown, isolate worker modules, and an in-process test harness.

Rate limiting (`RpcRateLimiter`) and the reconnecting client (`RpcClientConnection`) live in `package:rpc_dart`. They work with this framework, and the sections below show how.

The package uses `dart:io`. It does not run on the web.

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

Each module declares what it needs (`dependencies`), what it provides (`configure`, `configureWithEnv`, `onStart`), and how to clean up (`onStop`). The framework performs a topological sort, starts modules in dependency order, and stops them in reverse.

`RpcApp.start()` runs these steps in order:

1. Sort modules by `dependencies`.
2. For each module: `configure(container)`, then `configureWithEnv(container, env)`. Both are synchronous.
3. Spawn the isolate of each `RpcIsolateModule`.
4. For each module: `await onStart(container)`.
5. Build and start the transport server. For each new connection, the app adds the `onError` / `onCall` hooks, the `interceptors`, the `middlewares`, registers every server module's `buildContracts`, and starts the endpoint.
6. Call `afterModulesStart(container)`, if given.

Every `onStart` finishes before the server accepts a connection, so `buildContracts` can resolve what `onStart` registers.

A failed start rolls back in the order `stop()` uses: the server stops, started modules get `onStop`, isolates are terminated, and the error is rethrown. `start()` runs once per `RpcApp`; a second call throws, even after `stop()`. To restart, create a new `RpcApp`.

---

## RpcApp

The single entry point for server applications.

```dart
final logs = LogController();
final log = logs.scope('my-service');

await RpcApp.server(
  modules: [
    PostgresModule(),
    UserModule(),   // depends on PostgresModule
  ],
  server: (onEndpoint) => RpcHttp2Server(
    host: '0.0.0.0',
    port: 50051,
    onEndpointCreated: onEndpoint,
  ),
  interceptors: [authInterceptor, rateLimiter],
  config: RpcAppConfig(
    env: Platform.environment,
    logger: log,
    onError: (e, st, service, method) =>
        log.error('$service/$method failed', error: e, stackTrace: st),
    onCall: (event) => metrics.record(event),
  ),
).run(); // blocks until SIGTERM / SIGINT, then stops cleanly
```

`server` receives an `onEndpoint` callback. Pass it to the server's endpoint-created hook. If you do not, no contracts are registered and the app serves nothing. `RpcApp.server` also takes `middlewares` and `afterModulesStart`.

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

  Database? _db;

  // Sync, before the server starts. Register everything that
  // buildContracts resolves here.
  @override
  void configureWithEnv(RpcContainer c, RpcEnvConfig env) {
    final db = Database(
      host: env['PG_HOST'] ?? 'localhost',
      port: env.getInt('PG_PORT') ?? 5432,
    );
    _db = db;
    c.registerSingleton<Database>(db);
  }

  // Async, after the server has started: open connections.
  @override
  Future<void> onStart(RpcContainer c) => _db!.connect();

  @override
  Future<void> onStop() async => _db?.close();

  // Return null to skip health reporting for this module.
  @override
  Future<RpcHealthStatus?> checkHealth() async {
    try {
      await _db?.ping();
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
        db: c.get<Database>(), // shared singleton — OK
        // do NOT store per-connection state in the module class itself
      ),
    ];
  }
}
```

### RpcIsolateModule

Runs contract handlers in a dedicated Dart isolate. Use for CPU-intensive work (encryption, image processing, heavy computation) that would block the main event loop.

```dart
// 1. Worker entrypoint — must be a top-level or static function
//    (Isolate.spawn requirement).
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
  Map<String, dynamic> get isolateParams => const {}; // sendable values only

  @override
  List<RpcResponderContract> buildProxyContracts(RpcCallerEndpoint caller) {
    return [HashingProxyContract(caller)]; // forwards to worker via RPC-over-isolate
  }
}
```

`RpcIsolateEntrypoint` comes from `package:rpc_dart_isolate`. The app spawns and terminates the isolate itself; do not call `initIsolate()` or `terminateIsolate()`.

**How requests flow:**

```
Client ──network──► RpcResponderEndpoint (main isolate)
                          │ proxy contract
                    RpcCallerEndpoint ──IsolateTransport──► RpcResponderEndpoint (worker)
                                                                  │ real handler
                                                               result
```

The isolate transport (`rpc_dart_isolate`) uses `SendPort` / `ReceivePort` and multiplexes calls over stream IDs, like the network transports. Messages cross by `SendPort.send`, which copies them; see that package's README for the details. The worker isolate has no access to the main isolate's `RpcContainer`; pass any needed config through `isolateParams`.

### Dependency ordering

`dependencies` contains **Type** references, not instances:

```dart
@override
List<Type> get dependencies => [PostgresModule, RedisModule];
```

The framework topologically sorts all modules and guarantees:
- Start order respects dependencies (dependencies first).
- Stop order is reversed (dependents stop before their dependencies).
- A dependency type with no module in the `modules` list throws at startup.
- Circular dependencies throw at startup.

Both errors are `RpcStatusException` with `RpcStatus.failedPrecondition`.

---

## RpcContainer — dependency injection

Type-keyed singleton and factory registry.

```dart
// Registration
c.registerSingleton<Database>(Database(host: 'localhost', port: 5432));
c.registerLazySingleton<UserCache>((c) => UserCache(c.get<Database>()));
c.registerFactory<UserService>((c) => UserService(c.get<Database>()));

// Resolution
final db = c.get<Database>();             // throws if absent
final maybeDb = c.tryGet<Database>();     // null if absent
final exists = c.has<Database>();
```

- `registerSingleton` stores one instance.
- `registerLazySingleton` builds one instance on the first `get<T>()` and returns it afterwards.
- `registerFactory` builds a new instance on every `get<T>()`.
- `get<T>()` on a missing type throws `RpcStatusException` (`failedPrecondition`). `tryGet<T>()` returns null only when the type is not registered; a throwing factory still throws.
- `clear()` removes all registrations.

Register synchronous things in `configure` / `configureWithEnv`, and do async initialisation in `onStart`. Both finish before the server accepts a connection, so `buildContracts` can resolve either.

---

## RpcEnvConfig — environment variables

Typed, null-safe access to a `Map<String, String>`.

```dart
final url = env.require('DATABASE_URL');          // String — throws if missing or empty
final optional = env['OPTIONAL_KEY'];             // String?
final port = env.getInt('PORT') ?? 8080;          // int?
final workers = env.requireInt('WORKERS');        // int — throws if missing
final ratio = env.getDouble('SAMPLE_RATIO');      // double?
final debug = env.getBool('DEBUG');               // true for 'true', '1', 'yes' (any case)
final timeout = env.getDuration('TIMEOUT');       // parses '30s', '5m', '2h', '100ms'
final origins = env.getList('ALLOWED_ORIGINS');   // splits on comma, trims whitespace
final hasKey = env.has('API_KEY');                // present and non-empty
```

`getBool` takes `defaultValue:` (default `false`) for an absent key. `getList` takes `separator:` (default `','`). `require` and `requireInt` throw `RpcStatusException` (`failedPrecondition`).

Pass the env map via `RpcAppConfig.env`:

```dart
RpcAppConfig(env: Platform.environment)
// or override specific values in tests:
RpcAppConfig(env: {'PORT': '9090', 'DEBUG': 'true'})
```

Without `env`, the app reads `Platform.environment`.

---

## RpcAppConfig — hooks and timeouts

```dart
RpcAppConfig(
  env: Platform.environment,
  logger: logs.scope('service-name'),     // LogScope?; null = silent
  logController: logs,                    // enables context.log in handlers
  shutdownTimeout: Duration(seconds: 30), // per-module onStop timeout
  drainTimeout:    Duration(seconds: 10), // wait for in-flight calls to finish

  // Called for every exception that escapes a contract handler.
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

`logger` is a `LogScope` and `logController` a `LogController`, both from `rpc_dart`.

`onError` and `onCall` are automatically wired as interceptors covering all four call types (unary, server-stream, client-stream, bidirectional). `onError` runs, then the exception is rethrown. `RpcCallEvent` carries `serviceName`, `methodName`, `callType`, `duration`, `success`, `error` and `context`.

`stop()` stops the server with `drainTimeout` (it stops admitting and lets in-flight calls finish), then calls `onStop()` in reverse order, each bounded by `shutdownTimeout`, then terminates isolates. It waits for a `start()` still in progress, and concurrent calls share one stop.

---

## RpcRateLimiter

`RpcRateLimiter` and `RateLimit` are in `package:rpc_dart`. The limiter is an `IRpcInterceptor`; pass it in `interceptors` of `RpcApp.server` or `RpcTestApp.start`. Two algorithms:

| Algorithm | API | Characteristics |
|---|---|---|
| Sliding window | `RateLimit.slidingWindow(max:, window:)` | Two fixed-window buckets, O(1), no burst above `max` |
| Token bucket | `RateLimit.tokenBucket(max:, window:, burst:)` | Burst-tolerant, O(1); `burst` defaults to `max` |

```dart
final limiter = RpcRateLimiter(
  // Single shared counter across all callers. A ceiling on every call.
  global: RateLimit.slidingWindow(max: 10000, window: Duration(seconds: 1)),

  // Per-service counter. Keys are service names.
  perService: {
    'BlobService': RateLimit.tokenBucket(max: 200, window: Duration(seconds: 1), burst: 400),
  },

  // Per-method counter. Keys are 'Service.method'.
  perMethod: {
    'UserService.deleteUser': RateLimit.slidingWindow(max: 10, window: Duration(minutes: 1)),
  },

  // Extract a per-caller key from the call.
  // When set, perService and perMethod create independent counters per key.
  // A null key charges global alone.
  keyExtractor: (call) => call.context.getValue<String>('userId'),

  // Catch-all: applies per (key, method) for any call no other spec matches.
  perKeyFallback: RateLimit.slidingWindow(max: 50, window: Duration(seconds: 1)),
);

// Call dispose() on shutdown to cancel the cleanup timer.
limiter.dispose();
```

**Which counters a call charges:**

```
global (always, shared)  AND  the first match of:
perMethod[key] → perService[key] → perKeyFallback[key:method]
```

Both must admit, so the tighter of the two binds. Without `keyExtractor` all counters are shared (no per-key isolation).

Exceeding a limit throws `RpcRateLimitException` (an `RpcStatusException` with `RpcStatus.resourceExhausted`), which reaches the client as an RPC error. Other options: `cleanupInterval`, `maxTrackedKeys`, `meterServerStreamMessages`. See the `rpc_dart` README for how streaming calls are metered.

---

## RpcClientConnection

`RpcClientConnection` is in `package:rpc_dart`. It is a reconnecting client transport with observable connection state. Use it directly in Flutter/client apps — no module system needed. Inside a server app, create it in a plain `RpcModule`'s `onStart` and dispose it in `onStop`.

```dart
final connection = RpcClientConnection(
  transportFactory: () async {
    final ch = WebSocketChannel.connect(Uri.parse(serverUrl));
    await ch.ready;
    return RpcWebSocketCallerTransport(ch);
  },
  backoff: ExponentialBackoff(
    baseDelay: Duration(seconds: 1),
    maxDelay: Duration(seconds: 30),
  ),
  // Return false to stop reconnecting (session expired, payment required, etc.)
  shouldReconnect: (error) => !error.toString().contains('unauthenticated'),
);

// Create the endpoint ONCE — it survives reconnects.
// Calls in flight on a dropped connection fail; new calls
// use the new underlying transport.
final endpoint = RpcCallerEndpoint(transport: connection.transport);
final api = MyCallerContract(endpoint);

// Observe state changes (integrate with BLoC, StreamBuilder, etc.)
connection.state.listen((state) => switch (state) {
  RpcClientOnline()                       => showConnected(),
  RpcClientOffline()                      => showReconnecting(),
  RpcClientConnecting(:final attempt)     => showAttempt(attempt),
  RpcClientDisconnected(:final reason)    => showError(reason),
  RpcClientIdle()                         => null,
});

connection.connect();           // start connecting
connection.forceReconnect();    // drop current transport, reconnect immediately
await connection.disconnect();  // stop reconnecting, stay idle (reusable)
await connection.dispose();     // permanent teardown
```

Other options: `maxAttempts`, `connectTimeout`, `logger`, `onStateChanged`. `currentState` returns the current state synchronously.

**States** (subclasses of `RpcClientConnectionState`):

| State | Meaning |
|---|---|
| `RpcClientIdle` | Not started or after `disconnect()` |
| `RpcClientConnecting(attempt)` | Waiting before attempt N (backoff delay) |
| `RpcClientOnline` | Transport ready |
| `RpcClientOffline` | Transport dropped, reconnect loop running |
| `RpcClientDisconnected(reason)` | Terminal — `shouldReconnect` returned false or attempts ran out |

**Backoff policies** (`BackoffPolicy`):

```dart
ExponentialBackoff(baseDelay: ..., maxDelay: ..., jitter: true) // the default
FixedBackoff(Duration(seconds: 5))                              // constant delay between attempts
```

---

## Health

`RpcApp.health()` returns an `RpcAppHealth` snapshot:

```dart
final health = await app.health();

health.level;    // RpcAppHealthLevel.healthy | degraded | unhealthy
health.isHealthy;
health.isServing; // healthy or degraded
health.checkedAt;

// Per-module breakdown (only modules that returned non-null from checkHealth())
health.modules;  // Map<String, Map<String, Object?>>: level, message, details

// Endpoint metrics, one map per active server endpoint
health.endpoints; // List<Map<String, Object?>>

health.toJson(); // ready for an HTTP health-check response body
```

Overall level is derived from the worst module level: any `unhealthy` or `closed` module → `unhealthy`; any `degraded` or `reconnecting` → `degraded`; all healthy → `healthy`. A module whose `checkHealth()` throws counts as `unhealthy`. Any server endpoint that is inactive or whose transport is closed makes the level `unhealthy`.

---

## Testing

### RpcTestApp

Runs the full module stack in-process over `RpcChannelTransport.memoryPair()` — no server, no network.

```dart
late RpcTestApp app;

setUp(() async {
  app = await RpcTestApp.start(
    modules: [UserModule(), PostgresModule()],
    interceptors: [authStubInterceptor],
    env: {'PG_HOST': 'localhost'},
  );
});

tearDown(() => app.dispose());

test('getUser returns correct user', () async {
  final client = UserCallerContract(app.caller);
  final user = await client.getUser(GetUserRequest(id: '1'));
  expect(user.name, 'Alice');
});
```

`RpcTestApp.start` takes `modules`, `interceptors`, `middlewares` (responder side), `callerInterceptors`, `callerMiddlewares` (caller side), `config`, and `env` (overrides `config.env`). `app.health()` returns an `RpcAppHealth`. `dispose()` closes both endpoints, then stops modules and terminates isolates; it is safe to call twice.

`RpcTestApp` supports all module types (`RpcModule`, `RpcServerModule`, `RpcIsolateModule`), `RpcAppConfig` hooks, env overrides, and topological module ordering.

Limits:
- `memoryPair()` is zero-copy: codecs do not run. Test serialization over `RpcChannelTransport.pair()`.
- Contracts are built once (one connection), after `onStart`, as in `RpcApp`. Per-connection bugs do not show up here.

### RpcCallSpy

Interceptor that records every call passing through an endpoint. Useful for asserting interaction contracts.

```dart
final spy = RpcCallSpy();
// add to RpcTestApp interceptors or RpcApp.server interceptors

spy.entries;                           // List<RpcSpyEntry> — all calls, in order
spy.callsTo('UserService', 'getUser'); // filtered by service and method
spy.wasCalled('UserService', 'getUser');
spy.callCount;
spy.successCount;
spy.errorCount;
spy.reset();
```

Each `RpcSpyEntry` has `serviceName`, `methodName`, `callType`, `success`, `error`, `duration`, `calledAt` and `context`. An unbounded spy keeps every entry; pass `RpcCallSpy(maxEntries: 1000)` to drop the oldest.

### RpcFaultInjector

Interceptor that injects errors or latency into specific methods. Useful for resilience testing.

```dart
final injector = RpcFaultInjector()
  ..failMethod(
    'UserService',
    'getUser',
    RpcStatusException(RpcStatus.unavailable, 'forced error'),
  )
  ..failMethodOnce(
    'UserService',
    'listUsers',
    RpcStatusException(RpcStatus.internal, 'one-off error'),
  )
  ..delayMethod('BlobService', 'upload', Duration(seconds: 3));

// Remove the faults for one method
injector.removeMethod('UserService', 'getUser');

// Remove all faults
injector.clear();
```

`failMethodOnce` queues errors; each call takes the next one. When the queue is empty, a `failMethod` error for the same method applies. A delay runs before the error, so it affects both paths.
