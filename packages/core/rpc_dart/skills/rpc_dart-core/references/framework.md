<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Application framework (`rpc_dart_framework`)

`rpc_dart_framework` runs a server application built from **modules**. It
orders them by their dependencies, gives them a type-keyed DI container and
typed environment variables, builds the responder contracts for every incoming
connection, wires error and metrics hooks, aggregates health, and shuts down
gracefully on SIGTERM or SIGINT. It also ships an in-process test harness.

Use it for a server process with several services and shared resources
(database pools, caches, workers). For a single service, a client app, or a
test of one contract, use plain endpoints (`contracts-and-endpoints.md`): the
framework adds nothing there.

The package uses `dart:io`. It does not run on the web.

## Setup

```yaml
dependencies:
  rpc_dart: ^6.3.0
  rpc_dart_framework: ^0.5.0
  rpc_dart_http2: ^0.3.0 # or any transport package that ships an IRpcServer
```

```dart
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
```

## Rules

- A module subclasses `RpcModule` (infrastructure, no contracts),
  `RpcServerModule` (exposes contracts) or `RpcIsolateModule` (contracts run in
  a worker isolate). Override the `name` getter.
- `dependencies` is a `List<Type>` of module classes. Every listed type must be
  in the app's `modules` list, or startup throws. Cycles throw too. Modules
  start in dependency order and stop in reverse.
- `buildContracts` runs once **per connection**. Return new contract instances
  every time. Keep shared state in the container, not in the contract.
- Every module's `onStart` finishes before the transport server starts, so
  `buildContracts` can resolve what `onStart` registers.
- `RpcApp.start()` runs once. A second call, even after `stop()` or a failed
  start, throws. To restart, build a new `RpcApp`.
- A failed start rolls back in `stop()`'s order: the server stops, started
  modules get `onStop`, isolates are terminated, and the error is rethrown.
- `stop()` waits for a `start()` still in progress, and concurrent `stop()`
  calls share one stop.
- Errors from the framework (missing registration, missing env variable,
  unknown dependency, cycle) are `RpcStatusException` with
  `RpcStatus.failedPrecondition`.

## Lifecycle

`RpcApp.start()` does, in order:

1. Sort modules by `dependencies`.
2. For each module: `configure(container)`, then
   `configureWithEnv(container, env)`. Both are synchronous.
3. Spawn the isolate of each `RpcIsolateModule`.
4. For each module: `await onStart(container)`.
5. Build and start the server. For each new connection the server calls back
   with a `RpcResponderEndpoint`; the app adds the `onError`/`onCall` hooks,
   the `interceptors:`, the `middlewares:`, registers every server module's
   `buildContracts`, and starts the endpoint.
6. `afterModulesStart(container)`, if given.

`stop()` stops the server with `drainTimeout` (it stops admitting and lets
in-flight calls finish), then calls `onStop()` in reverse order, each bounded by
`shutdownTimeout`, then terminates isolates. `run()` is `start()`, a wait for
SIGTERM or SIGINT, then `stop()`.

## Main types

| Type | Purpose |
| --- | --- |
| `RpcApp.server(modules:, server:, interceptors:, middlewares:, afterModulesStart:, config:)` | The app. `server` is `IRpcServer Function(void Function(RpcResponderEndpoint) onEndpoint)`. Members: `start()`, `stop()`, `run()`, `health()` |
| `RpcModule` | `name`, `dependencies`, `configure`, `configureWithEnv`, `onStart`, `onStop`, `checkHealth` (returns `RpcHealthStatus?`; `null` skips the module) |
| `RpcServerModule` | adds `buildContracts(RpcContainer)` |
| `RpcIsolateModule` | `workerEntrypoint`, `isolateParams`, `buildProxyContracts(RpcCallerEndpoint)` |
| `RpcContainer` | `registerSingleton<T>`, `registerLazySingleton<T>`, `registerFactory<T>` (new instance per `get`), `get<T>`, `tryGet<T>`, `has<T>`, `clear` |
| `RpcEnvConfig` | `env['KEY']`, `require`, `getInt`, `requireInt`, `getDouble`, `getBool`, `getList`, `getDuration` (`300ms`, `30s`, `5m`, `2h`), `has`, `keys` |
| `RpcAppConfig` | `shutdownTimeout` (30 s), `drainTimeout` (10 s), `logger` (`LogScope?`), `logController`, `onError`, `onCall`, `env` |
| `RpcAppHealth` | `level` (`RpcAppHealthLevel`), `isHealthy`, `isServing`, `modules`, `endpoints`, `checkedAt`, `toJson()` |
| `RpcTestApp` | `RpcTestApp.start(...)`, `caller`, `health()`, `dispose()` |
| `RpcCallSpy` | interceptor that records calls: `entries`, `callCount`, `successCount`, `errorCount`, `callsTo`, `wasCalled`, `reset`; `maxEntries:` caps retention |
| `RpcFaultInjector` | interceptor: `failMethod`, `failMethodOnce`, `delayMethod`, `removeMethod`, `clear` |

Rate limiting (`RpcRateLimiter`) and the reconnecting client
(`RpcClientConnection`) live in `package:rpc_dart`, not here. See
`errors-and-resilience.md`. Pass a limiter in `interceptors:`.

## Modules

The contracts below are hand-written (see `contracts-and-endpoints.md`).
Generated responders plug in the same way.

```dart
import 'package:rpc_dart_framework/rpc_dart_framework.dart';

final class GreetingStore {
  GreetingStore(this.prefix);
  final String prefix;
  bool open = false;
}

final class AppGreeterResponder extends RpcResponderContract {
  AppGreeterResponder(this._store) : super('Greeter');
  final GreetingStore _store;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'hello',
      handler: _hello,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _hello(RpcString request, {RpcContext? context}) async =>
      RpcString('${_store.prefix}, ${request.value}');
}

final class AppGreeterCaller extends RpcCallerContract {
  AppGreeterCaller(RpcCallerEndpoint endpoint) : super('Greeter', endpoint);

  Future<RpcString> hello(RpcString request) => callUnary<RpcString, RpcString>(
    methodName: 'hello',
    request: request,
    requestCodec: RpcString.codec,
    responseCodec: RpcString.codec,
  );
}

/// Infrastructure: owns a shared resource, no contracts.
final class StoreModule extends RpcModule {
  @override
  String get name => 'Store';

  // Registered before the server starts, so buildContracts can resolve it.
  @override
  void configureWithEnv(RpcContainer container, RpcEnvConfig env) {
    container.registerSingleton<GreetingStore>(
      GreetingStore(env['GREETING'] ?? 'Hello'),
    );
  }

  @override
  Future<void> onStart(RpcContainer container) async {
    container.get<GreetingStore>().open = true;
  }

  @override
  Future<RpcHealthStatus?> checkHealth() async =>
      RpcHealthStatus.healthy(component: name);
}

/// Exposes the service. buildContracts runs once per connection.
final class GreeterModule extends RpcServerModule {
  @override
  String get name => 'Greeter';

  @override
  List<Type> get dependencies => [StoreModule];

  @override
  List<RpcResponderContract> buildContracts(RpcContainer container) => [
    AppGreeterResponder(container.get<GreetingStore>()),
  ];
}
```

## Running the server

```dart
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';

Future<void> serve() async {
  final app = RpcApp.server(
    modules: [GreeterModule(), StoreModule()], // order does not matter
    server: (onEndpoint) => RpcHttp2Server(
      host: '0.0.0.0',
      port: 50051,
      onEndpointCreated: onEndpoint,
    ),
    config: RpcAppConfig(
      drainTimeout: const Duration(seconds: 5),
      onError: (error, stackTrace, service, method) =>
          print('$service.$method failed: $error'),
      onCall: (event) =>
          print('${event.serviceName}.${event.methodName} ${event.duration}'),
    ),
  );
  await app.run(); // returns after SIGTERM / SIGINT and a clean stop
}
```

Pass the `onEndpoint` callback to the server's endpoint-created hook. If you
do not, no contracts are registered and the app serves nothing. Servers that create their endpoint late (`RpcHttpServer`) are finished
in `afterModulesStart`; see that transport's README.

`onError` runs for every exception that escapes a handler, then the exception
is rethrown. `onCall` gets an `RpcCallEvent` (`serviceName`, `methodName`,
`callType`, `duration`, `success`, `error`, `context`) after each call.

`await app.health()` returns `RpcAppHealth`. The level is the worst over the
modules, where a module's `closed` counts as `unhealthy` and `reconnecting` as
`degraded`, and `unhealthy` when any server endpoint is inactive or its
transport closed. Serve `toJson()` from a health check.

## Isolate modules

`RpcIsolateModule` spawns a worker isolate at startup. The worker runs the real
handlers; on the main isolate, `buildProxyContracts` returns responders that
forward each call over the isolate transport. The worker has no access to the
container: pass configuration through `isolateParams` (sendable values only).

```dart
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';

// Must be a top-level or static function.
void greeterWorker(IRpcTransport transport, Map<String, dynamic> params) {
  RpcResponderEndpoint(transport: transport)
    ..registerServiceContract(
      AppGreeterResponder(GreetingStore(params['prefix'] as String)),
    )
    ..start();
}

final class ProxyGreeterResponder extends RpcResponderContract {
  ProxyGreeterResponder(RpcCallerEndpoint worker)
    : _worker = AppGreeterCaller(worker),
      super('Greeter');
  final AppGreeterCaller _worker;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'hello',
      handler: (request, {context}) => _worker.hello(request),
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}

final class IsolateGreeterModule extends RpcIsolateModule {
  @override
  String get name => 'IsolateGreeter';

  @override
  RpcIsolateEntrypoint get workerEntrypoint => greeterWorker;

  @override
  Map<String, dynamic> get isolateParams => const {'prefix': 'Hi'};

  @override
  List<RpcResponderContract> buildProxyContracts(RpcCallerEndpoint caller) => [
    ProxyGreeterResponder(caller),
  ];
}
```

## Testing with `RpcTestApp`

`RpcTestApp.start` runs the same modules over `RpcChannelTransport.memoryPair()`
with no server. It takes `modules:`, `interceptors:`, `middlewares:`,
`callerInterceptors:`, `callerMiddlewares:`, `config:` and `env:` (overrides
`config.env`). Call contracts on `app.caller`; `dispose()` closes both
endpoints, then stops modules.

```dart
import 'package:rpc_dart_framework/rpc_dart_framework.dart';

Future<void> main() async {
  final spy = RpcCallSpy();
  final faults = RpcFaultInjector()
    ..failMethodOnce(
      'Greeter',
      'hello',
      RpcStatusException(RpcStatus.unavailable, 'try again'),
    );

  final app = await RpcTestApp.start(
    modules: [GreeterModule(), StoreModule()],
    interceptors: [spy, faults],
    env: {'GREETING': 'Hi'},
  );
  try {
    final greeter = AppGreeterCaller(app.caller);
    try {
      await greeter.hello(const RpcString('Ada'));
      throw StateError('expected the injected fault');
    } on RpcStatusException catch (e) {
      if (e.statusCode != RpcStatus.unavailable) rethrow;
    }

    final reply = await greeter.hello(const RpcString('Ada'));
    if (reply.value != 'Hi, Ada') throw StateError(reply.value);
    if (spy.callsTo('Greeter', 'hello').length != 2) throw StateError('spy');
    if (!(await app.health()).isHealthy) throw StateError('health');
  } finally {
    await app.dispose();
  }
}
```

## Pitfalls

- These do NOT exist in this package: `RpcClientModule`, `RpcRateLimiter`,
  `RateLimit`, `RpcClientConnection` (the last three are in `rpc_dart`),
  `RpcCallSpy.calls`, `callsFor`, `RpcFaultInjector.injectError`,
  `injectDelay`, `clearFault`.
- `RpcCallSpy` and `RpcFaultInjector` take the service and method as two
  arguments: `callsTo('Greeter', 'hello')`, not `'Greeter/hello'`.
- `RpcContainer.get` on a missing type throws `RpcStatusException`, not
  `StateError`. `tryGet` returns `null` only when the type is not registered;
  a throwing factory still throws.
- `registerFactory` builds a new instance on every `get`. For one shared
  instance use `registerSingleton` or `registerLazySingleton`.
- Storing per-connection state in a module field: modules are shared by every
  connection.
- `RpcEnvConfig.require` treats an empty value as missing. `getBool` is true
  for `true`, `1` and `yes` (any case).
- `RpcTestApp` uses `memoryPair()`, which is zero-copy: codecs do not run.
  Test serialization over `RpcChannelTransport.pair()` (`testing.md`).
- `RpcTestApp` builds contracts once (one connection), so it does not
  reproduce per-connection bugs.
- An unbounded `RpcCallSpy` in a long-running server keeps every call's
  context. Pass `maxEntries:` or do not use it outside tests.
- Calling `initIsolate()` / `terminateIsolate()` yourself: the app does it.

The full reference, including more examples per type, is the
`rpc_dart_framework` README. Where it disagrees with this file, the code wins.
