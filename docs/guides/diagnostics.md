<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Diagnostics & health checks

Visibility is critical when you run RPC Dart in production. The library ships
with health reporting, active ping support, and a configurable logging system to
help you troubleshoot issues without redeploying instrumentation.

## Endpoint health snapshots

`RpcCallerEndpoint.health()` and `RpcResponderEndpoint.health()` return
`RpcEndpointHealth`, a composite structure that includes:

- `endpointStatus` – overall status of the endpoint lifecycle (`active`,
  `degraded`, `closed`, etc.).
- `dependencies` – map of component names (usually transports) to their
  `RpcHealthStatus`.
- `transportStatus` – convenience getter exposing the primary transport.
- `timestamp` – when the snapshot was generated.

```dart
final report = await callerEndpoint.health();
if (!report.isHealthy) {
  final transport = report.transportStatus;
  logger.warning('Caller degraded: ${transport?.message}', data: transport?.details);
}
```

Call `reconnect()` to delegate recovery to the transport. Transports that support
automatic reconnection return `RpcHealthStatus.reconnecting` until the link is
stable again.

## Active ping between endpoints

`RpcCallerEndpoint.ping()` performs a round-trip check using the built-in system
service `_rpc.System/Ping`.

```dart
final result = await callerEndpoint.ping(timeout: const Duration(seconds: 1));
print('RTT: ${result.roundTrip.inMilliseconds} ms');
print('Responder: ${result.responderDebugLabel}');
```

The result includes:

- `roundTrip` – measured latency.
- `responderTimestamp` – when the responder processed the ping.
- `responderDebugLabel` and `responderTransportType` – diagnostic headers
  supplied by the responder endpoint.
- `responseHeaders` – raw metadata for custom analysis.

Ping uses the same transport pipeline as regular calls, so you can detect routing
issues, TLS problems, or degraded links in real time.

## Logging with `LogController` and `LogScope`

Two objects. **`LogController`** is the dispatcher: every record passes through
level filter, sampling, enrichers, redaction, then outputs. **`LogScope`** is a
cheap handle bound to a controller and a name, and it is what you actually call.

```dart
final controller = LogController(LogConfig(minLevel: RpcLogLevel.debug));
final log = LogScope(controller, 'BillingService');

log.info('Responder started', data: {'endpoints': 3});
```

`LogScope.noop` is a zero-cost handle for when logging is off — it implements the
same interface and does nothing, so call sites need no null checks.

A scope carries correlation for you: `traceId`, `requestId` and `parentSpanId`
are constructor parameters, and the responder pipeline attaches a scope with the
service and method name already bound.

## Spans

`startSpan` returns a `LogSpanHandle` for timing a unit of work; the handle can
emit events and open child spans, and produces a `LogSpan` record when ended.

```dart
final span = log.startSpan('charge-card', data: {'attempt': 1});
span.event('gateway accepted');
span.end();
```

**Spans bypass the level filter** — they are telemetry rather than logs. Turn
them off with `spansEnabled` in `LogConfig` if you do not want them.

## Outputs, enrichment and redaction

`LogOutput` is the sink interface, with `write()` and `writeAsync()` plus an
`isAsync` flag, so an HTTP or database backend is a normal implementation rather
than a special case. `ConsoleOutput` (pretty, json or compact) and
`RingBufferOutput` ship with the library.

Three hooks, all changeable at runtime: `addEnricher()` / `removeEnricher()` to
attach fields to every record, `setRedactor()` to swap a `LogRedactor` (which
matches `field=value` patterns inside messages and errors, not just data
fields), and `LogController(clock: () => myTime)` for deterministic timestamps in
tests — the clock propagates through scopes and spans.

Applied log tooling — remote collection, shipping logs over RPC — lives in the
separate `rpc_dart_log` package.

## Transport diagnostics

Every `IRpcTransport` implements `health()` and `reconnect()`, so you can gather
per-transport metrics even when multiple transports are routed together via
`RpcTransportRouter`. Health details expose flags such as `supportsZeroCopy`,
`activeStreams`, and `isClosed`—perfect for exporting to Prometheus or custom
metrics collectors.

Combine these tools to build dashboards, trigger alerts, and keep latency under
control as your system grows.
