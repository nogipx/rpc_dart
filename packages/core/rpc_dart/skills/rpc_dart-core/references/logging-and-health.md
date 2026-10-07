<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Logging and health

## Logging rules

- Create one `LogController` per process (or per test) and pass it to every
  endpoint as `logger:`. Endpoints take a `LogController`, NOT a `LogScope`.
  Without `logger:` an endpoint logs nothing.
- `LogController` takes named parameters only. There is no `LogConfig`
  argument; `LogConfig` is a read-only snapshot from `controller.config`.
- Inside your own classes hold a non-nullable `LogScope`, default it to
  `LogScope.noop`, and get real scopes from `controller.scope('name')`.
- Guard every interpolating `internal`/`trace`/`debug` call with
  `isInternal`/`isTrace`/`isDebug`. The message string is built before the
  level check otherwise.
- In a handler, log through `context?.log`. It is already scoped to the method
  and carries the call's `traceId` and `requestId`.
- `data:` is `Map<String, Object>` (non-nullable values). Convert a
  `Map<String, Object?>` (for example health `details`) before passing it.
- Call `controller.dispose()` at shutdown; it disposes every output.

### LogController

| Parameter | Default | Meaning |
| --- | --- | --- |
| `minLevel` | `RpcLogLevel.debug` | Global threshold for events. Mutable field. |
| `spansEnabled` | `true` | Spans bypass level filtering and sampling; this turns them off. Mutable field. |
| `clock` | `DateTime.now` | Timestamp source; inject a fake in tests. |
| `outputs` | `[]` | `LogOutput` sinks. |
| `enrichers` | `[]` | `LogEnricher`s adding fields to every record. |
| `sampling` | `null` | `SamplingConfig(interval:, maxPerInterval: {level: n})`. |
| `redactFields` | `[]` | Case-insensitive keys whose values become `[REDACTED]` in `data`, and `key=value` / `key: value` in messages and error text. |

Runtime methods: `setScopeLevel(prefix, level)` / `clearScopeLevel`,
`setTagLevel(tag, level)` / `clearTagLevel`, `addOutput` / `removeOutput`,
`addEnricher` / `removeEnricher`, `setRedactor(LogRedactor?)`, `stream`
(broadcast of records that passed), `scope(name, {tag})`, `config`, `dispose()`.

Pipeline order: level filter -> sampling -> enrich -> redact -> outputs ->
`stream`. A throwing output is isolated; it never reaches the caller.

`RpcLogLevel`, ascending: `internal`, `trace`, `debug`, `info`, `warning`,
`error`, `fatal`. `internal` is the library's own frame-level chatter; it is
below the default `minLevel`.

Endpoint scope names: `rpc.caller`, `rpc.responder`, `rpc.peer`. Handler
scopes are `<endpoint scope>.<Service>.<method>`, for example
`rpc.responder.Echo.echo`. Use these with `setScopeLevel`.

```dart
import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';

final logger = LogController(
  minLevel: RpcLogLevel.info,
  outputs: [ConsoleOutput(format: ConsoleFormat.compact, colored: false)],
  redactFields: ['authorization', 'password'],
);

(RpcCallerEndpoint, RpcResponderEndpoint) wireWithLogging() {
  logger.setScopeLevel('rpc.responder', RpcLogLevel.debug);
  final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();
  final responder = RpcResponderEndpoint(
    transport: serverTransport,
    logger: logger,
  );
  final caller = RpcCallerEndpoint(transport: clientTransport, logger: logger);
  return (caller, responder);
}
```

### LogScope

Methods: `internal`, `trace`, `debug`, `info` (message, `data:`);
`warning`, `error`, `fatal` (message, `error:`, `stackTrace:`, `data:`).
Derivation: `child(name)` (appends `.name`), `withTag(tag)`,
`withData(map)` (bound to every record), `withContext(traceId:, requestId:)`.
Spans: `startSpan(name)` returns a `LogSpanHandle` (`event`, `addData`,
`startSpan`, `end(status:, error:, stackTrace:)`); `withSpan(name, body)` and
`withSpanSync` end the span with `SpanStatus.ok` or `SpanStatus.error`
and rethrow.

```dart
final class OrderService {
  OrderService({LogScope? logger}) : _log = logger ?? LogScope.noop;

  final LogScope _log;

  Future<void> place(String orderId) => _log.withSpan('place', (span) async {
    if (_log.isDebug) {
      _log.debug('placing $orderId');
    }
    span.event('validated');
    _log.info('placed', data: {'orderId': orderId});
  });
}

final service = OrderService(logger: logger.scope('app.orders'));
```

In a handler (`context` is nullable in the handler signature):

```dart
Future<RpcString> echo(RpcString request, {RpcContext? context}) async {
  context?.log.info('echo', data: {'length': request.value.length});
  return request;
}
```

### Outputs, enrichers, sampling

- `ConsoleOutput({colored = true, format = ConsoleFormat.pretty, scopeFilter})`;
  formats `pretty`, `json`, `compact`. Uses `print`.
- `RingBufferOutput({maxEntries = 1000, scopeFilter})`; read with `entries`,
  `query(LogFilter(...), limit:)`, `length`, `clear()`. Use it in tests and for
  an in-app log viewer.
- `scopeFilter` is a scope-name PREFIX; records outside it skip that output.
- Records are a sealed `LogRecord`: `LogEvent` (level, message, tag, error,
  traceId, requestId, data), `LogSpanStart`, `LogSpan` (duration, status).

```dart
final class ErrorCounter extends LogOutput {
  int errors = 0;

  @override
  void write(LogRecord record) {
    if (record is LogEvent && record.level >= RpcLogLevel.error) errors++;
  }
}

final class HostEnricher implements LogEnricher {
  @override
  Map<String, Object> enrich(LogRecord record) => {'host': 'api-1'};
}

final production = LogController(
  minLevel: RpcLogLevel.info,
  outputs: [ConsoleOutput(format: ConsoleFormat.json), ErrorCounter()],
  enrichers: [HostEnricher()],
  sampling: const SamplingConfig(maxPerInterval: {RpcLogLevel.info: 100}),
);
```

For async sinks override `isAsync => true` and `writeAsync`. To ship logs or
traces elsewhere use the `rpc_dart_log` and `rpc_dart_opentelemetry` packages;
they plug into this `LogController`.

## Health

- `endpoint.health()` returns `Future<RpcEndpointHealth>` on every endpoint.
- `RpcEndpointHealth`: `isHealthy` (endpoint and all dependencies healthy),
  `endpointStatus` (an `RpcHealthStatus`), `dependencies` (map; key
  `'transport'`), `transportStatus` (shortcut for `dependencies['transport']`,
  nullable), `timestamp`. There is no `level` on it; read
  `endpointStatus.level`.
- `RpcHealthStatus`: `component`, `level`, `message`, `details`
  (`Map<String, Object?>`), `timestamp`, `isHealthy`.
- `RpcHealthLevel`, ascending severity: `healthy`, `reconnecting`, `degraded`,
  `unhealthy`, `closed`. Compare with `.severity` (0..4).
- An active endpoint over a closed transport reports `endpointStatus.level ==
  degraded` and `transportStatus.level == closed`. A closed endpoint reports
  `closed`.
- `RpcChannelTransport` health details: `activeStreams`, `streamControllers`,
  `finishedStreams`, `statusSeen`, `zeroCopy` (bool). Other transports report
  their own keys.
- `endpoint.reconnect()` returns an updated `RpcEndpointHealth`. On
  `RpcChannelTransport` it reports `degraded` with `details['supported'] ==
  false`: create a new transport instead.

```dart
Future<void> checkHealth(RpcCallerEndpoint caller, LogScope log) async {
  final report = await caller.health();
  if (report.isHealthy) return;
  final transport = report.transportStatus;
  log.warning(
    'endpoint ${report.endpointStatus.level.name}: ${transport?.message}',
    data: {
      for (final e in (transport?.details ?? const {}).entries)
        if (e.value != null) e.key: e.value!,
    },
  );
}
```

### Ping

`ping({Duration? timeout, RpcContext? context})` is on `RpcCallerEndpoint` and
`RpcPeerEndpoint` (not on `RpcResponderEndpoint`). The responder answers it
automatically. Returns `RpcEndpointPingResult`: `sentAt`, `receivedAt`,
`roundTrip`, `responderTimestamp`, `responderDebugLabel`,
`responderTransportType`, `responseHeaders`.

```dart
Future<Duration?> probe(RpcCallerEndpoint caller) async {
  try {
    final pong = await caller.ping(timeout: const Duration(seconds: 2));
    return pong.roundTrip;
  } on TimeoutException {
    return null;
  } on RpcStatusException {
    return null;
  }
}
```

### Standard gRPC health service

`GrpcHealthCheckContract` implements `grpc.health.v1.Health` (`Check` unary,
`Watch` server stream), backed by a `GrpcHealthServiceStatus` you update.
Service name `''` means the whole server. `GrpcServingStatus`: `unknown`,
`serving`, `notServing`, `serviceUnknown`. An unregistered service answers
`serviceUnknown` in the response body, not a NOT_FOUND status.

```dart
GrpcHealthServiceStatus serveHealth(RpcResponderEndpoint responder) {
  final healthStatus = GrpcHealthServiceStatus()
    ..setStatus('', GrpcServingStatus.serving)
    ..setStatus('Echo', GrpcServingStatus.serving);
  responder.registerServiceContract(GrpcHealthCheckContract(healthStatus));
  return healthStatus;
}

void onShutdown(GrpcHealthServiceStatus healthStatus) {
  healthStatus.setStatus('', GrpcServingStatus.notServing);
  healthStatus.dispose();
}
```

Other methods: `getStatus`, `clearStatus`, `clearAll`, `changes`.

## Pitfalls

- `LogController(LogConfig(...))` does not compile. Use named parameters.
- `RpcLogger`, `InMemoryLogger`, `RpcLogger.setLoggerFactory`,
  `RpcGrpcHealthService`, `RpcGrpcHealthClient`, `ServingStatus` do not exist.
- Passing a `LogScope` as an endpoint's `logger:` is a type error; pass the
  `LogController`.
- `RpcHealthLevel` has no `active`; `RpcEndpointHealth` has no `level`.
- `log.warning(..., data: status.details)` is a type error:
  `Map<String, Object?>` is not `Map<String, Object>`.
- `ping` timeout throws `dart:async` `TimeoutException`, not an
  `RpcStatusException`. Without `timeout:` the context deadline applies; with
  neither, ping waits indefinitely.
- `minLevel` defaults to `debug`, so a `LogController()` with a console output
  prints all debug traffic. Set `minLevel: RpcLogLevel.info` in production.
- Spans ignore `minLevel`; disable them with `spansEnabled: false`.
- `redactFields` only masks `data` keys and `key=value` / `key: value` text.
  It does not see values inside free-form messages.
- `GrpcHealthServiceStatus` holds a broadcast controller; call `dispose()`.
