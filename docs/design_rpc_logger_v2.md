<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# RPC Logger v2 — Design Document

## Status: IMPLEMENTED

Core logger module, spans, and full migration complete. Zero errors across monorepo.

---

## Mental Model

### The Pipe Analogy

```
[Source] --> [Pipe] --> [Drain]
```

- **Source** — any code that writes a log message (rpc_dart internals, your responder, your app)
- **Pipe** — `LogController` (filters, enriches, routes)
- **Drain** — `LogOutput` (console, remote peer, ring buffer, /dev/null)

The source doesn't know where the drain is. The drain doesn't know who the source is.
The pipe connects them.

### Three Roles

```
+-----------------------------------------------------------+
|                      YOUR PROCESS                         |
|                                                           |
|  +----------+         +--------------+                    |
|  | Endpoint |--------+|              |--+ ConsoleOutput   |
|  | internals| scope  ||              |                    |
|  +----------+        ||              |--+ RingBuffer      |
|                      || LogController|                    |
|  +----------+        ||              |--+ RpcLogOutput ------+ [Remote Peer]
|  |  Your    | scope  ||              |                    |
|  |Responders|--------+|              |                    |
|  +----------+         +--------------+                    |
|                                                           |
+-----------------------------------------------------------+
```

**Role 1: Writer** — writes log entries through a `LogScope`.
Knows nothing about outputs. Just calls `scope.info('...')`.

**Role 2: Controller** — owns the pipe. Filters, enriches, samples, routes.
Created once, injected into endpoint.

**Role 3: Output** — consumes entries. Can be local (print) or remote (RPC send).
Receives only entries that passed all filters.

### Propagation

The endpoint is the entry point for the logger. It propagates logging capability
downward to all internal components and to user responders:

```
User creates LogController
        |
        v
   RpcPeerEndpoint(logger: controller)
        |
        +-- internal transport  -> gets LogScope('rpc.peer.transport')
        +-- internal parser     -> gets LogScope('rpc.peer.parser')
        +-- internal streams    -> gets LogScope('rpc.peer.streams')
        |
        +-- user's responder handler
              |
              +-- RpcContext.log -> gets LogScope('rpc.peer.Calculator.calculate')
                                   with traceId + requestId auto-attached
```

Every component writes to its own `LogScope`. All scopes feed into the same
`LogController`. The user controls what gets through by setting the level.

### Zero-Cost When Disabled

```dart
// No logger passed — endpoint uses LogScope.noop
final endpoint = RpcPeerEndpoint();
// All internal _log.internal(...) calls hit noop — empty body, instant return

// For hot paths where even string interpolation matters:
if (_log.isInternal) _log.internal('heavy $computation');
```

If a logger IS passed but level is `info`, then `internal`/`trace`/`debug` entries
are rejected by the controller before reaching any output. No formatting, no I/O.

---

## Three Record Types

### LogEvent — "what happened"

A point-in-time event. The classic log message.

```dart
context?.log.info('Order created');
context?.log.error('Payment failed', error: e, stackTrace: st);
```

Properties:
- Has **level** (internal/trace/debug/info/warning/error/fatal)
- Filtered by level — `minLevel = warning` suppresses debug/info
- Subject to sampling in production
- If inside a span, carries `spanId` reference

### LogSpanStart — "operation began"

Marks the beginning of a span. Emitted when `startSpan()` / `withSpan()` is called.

```
[16:42:03.452] SPAN ea4d01 >> api.handleRequest
```

### LogSpan — "operation completed"

A completed operation with duration. Emitted when span ends.

```
[16:42:03.501] SPAN ea4d01 api.handleRequest 49ms [ok]
```

Properties:
- **No level** — this is telemetry, not a log message
- **Bypasses level filter** — even at `minLevel = fatal`, spans still pass
- Can be disabled entirely via `spansEnabled = false`
- Carries duration, status (ok/error), error info

### Console Output Format (logfmt-style)

```
[16:42:03.452] SPAN ea4d01 >> api.handleRequest
[16:42:03.452] INFO ea4d01 api  Parsing request body
[16:42:03.466] SPAN e25a03 >> api.db.query
[16:42:03.466] INFO e25a03 api  SELECT * FROM orders  trace=trace_abc123
[16:42:03.493] SPAN e25a03 api.db.query 27ms [ok]
[16:42:03.494] INFO ea4d01 api  Serializing response
[16:42:03.501] SPAN ea4d01 api.handleRequest 49ms [ok]
[16:42:03.548] SPAN 925e00 api.failingOp 7ms [ERROR]  err=Something went wrong
```

Format: `[time] TYPE [spanId] scope  message  key=value key=value`

- Span ID (6 hex chars) links events to their span visually
- `>>` marks span start
- traceId shown as `trace=...` (only when present)
- requestId NOT shown in pretty output (too noisy) — available in JSON format
- data shown as logfmt key=value pairs
- Strings with spaces are quoted: `key="value with spaces"`

---

## Processing Pipeline

```
LogScope.info('msg', data: {...})          LogSpanHandle.end()
    |                                           |
    v                                           v
LogController.add(LogEvent)                LogController.add(LogSpan)
    |                                           |
    +-- 1. Level/scope filter --> reject        +-- 1. spansEnabled? --> reject if false
    |                                           |      (NO level filter -- spans are telemetry)
    +-- 2. Sampling --> drop by rate            |
    |                                           |
    +------------ shared pipeline below --------+
    |
    +-- 3. Enrichers --> add fields (host, pid, environment, custom)
    |
    +-- 4. Redaction --> strip sensitive fields from data
    |
    +-- 5. Route to outputs (each output may have its own scope filter)
    |
    +-- 6. Stream --> broadcast to reactive consumers (if any listeners)
```

Steps 2-4 only run on entries that passed step 1.
Each step is optional — if not configured, it's skipped (zero overhead).

---

## Core Types (Implemented)

### RpcLogLevel

```dart
enum RpcLogLevel {
  internal, // library internals only (convention)
  trace,    // detailed diagnostics
  debug,    // development
  info,     // business events
  warning,  // recoverable issues
  error,    // failures
  fatal,    // unrecoverable
}
```

### LogRecord (sealed)

```dart
sealed class LogRecord {
  String get scope;
  DateTime get timestamp;
  Map<String, Object>? get data;
}

class LogSpanStart implements LogRecord { ... }  // span begin marker
class LogEvent implements LogRecord { ... }       // point-in-time event
class LogSpan implements LogRecord { ... }        // completed span with duration
```

### LogScope

```dart
class LogScope {
  static const noop = _NoopLogScope();

  // Level guards
  bool get isInternal;
  bool get isTrace;
  bool get isDebug;

  // Hierarchy
  LogScope child(String childName);
  LogScope withTag(String tag);
  LogScope withData(Map<String, Object> data);
  LogScope withContext({String? traceId, String? requestId});

  // Events
  void internal(String message, {Map<String, Object>? data});
  void trace(...); void debug(...); void info(...);
  void warning(..., {Object? error, StackTrace? stackTrace});
  void error(...); void fatal(...);

  // Spans
  LogSpanHandle startSpan(String name, {Map<String, Object>? data});
  Future<T> withSpan<T>(String name, Future<T> Function(LogSpanHandle) body);
  T withSpanSync<T>(String name, T Function(LogSpanHandle) body);
}
```

### LogController

```dart
class LogController {
  LogController({
    RpcLogLevel minLevel = RpcLogLevel.debug,
    bool spansEnabled = true,
    List<LogOutput> outputs,
    List<LogEnricher> enrichers,
    SamplingConfig? sampling,
    List<String> redactFields,
  });

  RpcLogLevel minLevel;
  bool spansEnabled;

  void setScopeLevel(String scope, RpcLogLevel level);
  void setTagLevel(String tag, RpcLogLevel level);
  bool accepts(RpcLogLevel level, String scope);

  void addOutput(LogOutput output);
  void removeOutput(LogOutput output);
  void add(LogRecord record);
  Stream<LogRecord> get stream;
  LogScope scope(String name, {String? tag});
  LogConfig get config;
  void dispose();
}
```

### LogOutput

```dart
abstract class LogOutput {
  String? get scopeFilter => null;
  void write(LogRecord record);
  void dispose() {}
}
```

---

## Built-in Outputs

| Output | Purpose |
|--------|---------|
| `ConsoleOutput` | Pretty/JSON/compact console printing with ANSI colors |
| `RingBufferOutput` | In-memory circular buffer, queryable by `LogFilter` |
| `RpcLogOutput` | Send records to remote peer via callbacks, offline buffer |

---

## RPC Layer

| Component | Role |
|-----------|------|
| `RpcLogResponder` | Accept records from remote peer, feed into local controller |
| `RpcLogServiceResponder` | Expose logs: subscribe(filter) stream + getHistory + remote control |
| `RpcLogServiceCaller` | Client API: subscribe, getHistory, setMinLevel, setScopeLevel |

Remote control methods: `setMinLevel`, `setScopeLevel`, `clearScopeLevel`, `getConfig`.

---

## Responder Scope (Auto-configured)

When a responder handler is called, `context.log` is automatically configured with:
- Scope: `rpc.{endpoint}.{ServiceName}.{methodName}`
- traceId from the RPC frame (auto-generated if not present)
- requestId from the RPC frame

```dart
Future<Response> onCalculate(Request req, {RpcContext? context}) async {
  context?.log.info('Processing');  // auto: scope, traceId, requestId
  return Response(...);
}
```

Console output:
```
[16:42:03] INFO rpc.responder.Calculator.calculate  Processing  trace=trace_abc123
```

---

## Design Principles

1. **Injection over globals** — no singletons, no static state
2. **Propagation over configuration** — endpoint receives logger once, everything below gets it
3. **Writers don't know readers** — LogScope has no reference to outputs
4. **Zero cost when off** — no logger = noop, wrong level = rejected before I/O
5. **Sync write, async transport** — `scope.info()` never blocks
6. **One controller, many scopes** — single filtering/routing point
7. **Outputs are composable** — add/remove at runtime
8. **Convention over restriction** — `internal` level reserved by convention
9. **Self-contained, convertible** — own format, zero deps; OTel export via output plugin
10. **Spans are telemetry, not logs** — bypass level filtering, always pass unless disabled

---

## Industry Validation

| Feature | Proven In | Our Implementation |
|---------|-----------|-------------------|
| Multiple outputs | All | LogOutput |
| Hierarchical scopes | All | LogScope.child() |
| Per-scope filtering | Java, .NET | setScopeLevel() |
| Structured data | Go, .NET, Rust | entry.data (logfmt in console) |
| Bound context | Go (zap.With), Node (pino) | LogScope.withData() |
| Sampling | Go (zap, zerolog) | SamplingConfig |
| Enrichers | .NET (Serilog) | LogEnricher |
| Redaction | Node (pino) | redactFields |
| Zero-cost noop | Go, Rust | LogScope.noop |
| Spans | Rust (tracing), OTel | LogSpan + LogSpanHandle |
| Remote diagnostics | APM tools | RpcLogServiceResponder |
| Remote control | Rare | setMinLevel/setScopeLevel via RPC |

---

## File Structure (Implemented)

```
lib/src/logger/
  _index.dart               // barrel export
  log_level.dart             // RpcLogLevel enum
  log_record.dart            // sealed: LogSpanStart, LogEvent, LogSpan
  log_scope.dart             // LogScope + _NoopLogScope
  log_span_handle.dart       // LogSpanHandle (active span)
  log_controller.dart        // LogController + LogConfig
  log_output.dart            // abstract LogOutput
  log_enricher.dart          // LogEnricher interface
  log_filter.dart            // LogFilter (for queries/subscriptions)
  sampling.dart              // SamplingConfig + SamplingState
  redaction.dart             // LogRedactor
  outputs/
    console_output.dart      // ConsoleOutput (pretty/json/compact)
    ring_buffer_output.dart  // RingBufferOutput
    rpc_log_output.dart      // RpcLogOutput (remote send + offline buffer)
  rpc/
    rpc_log_responder.dart          // accept remote logs
    rpc_log_service_responder.dart  // expose subscribe + history + control
    rpc_log_service_caller.dart     // client API for remote log service
```

Exported from `lib/logger.dart` and re-exported from `lib/rpc_dart.dart`.

---

## Non-Goals

- File output / rotation — implement `LogOutput`
- Crash reporting (Sentry) — implement `LogOutput`
- UI log viewer — use `stream` or `RingBufferOutput`
- OTel SDK compliance — export via output plugin
- Full APM — out of scope