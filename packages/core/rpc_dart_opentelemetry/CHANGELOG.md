## 0.3.6

**Observability (best-effort error sites):**
- `OtelRpcInterceptorBase._finish` / `_finishWithError`: the two `metrics?.recordCall(...)` calls were wrapped in empty `catch (_) {}`, so a misconfigured meter failed silently. The exception is still swallowed (telemetry must never break the wrapped RPC call), but it is now surfaced on the active span via a new `_recordMetricsFailure` helper that adds a `rpc.metrics.record_failed` span event (`log.level=debug`, `exception.message`, `exception.stacktrace`). No logger is injected into this class, so the span — the diagnostic facility it owns — is the cleanest sink.
- `LogControllerOtelOutput` (`dispose`, `_sweepExpired`, `_evictOverflow`): the three best-effort `span.end()` calls keep their empty `catch (_) {}` but now carry explicit comments documenting WHY the failure is intentionally not logged: this class IS a `LogOutput`, so routing an OTel export failure into a logger would re-enter the same `LogController` that feeds this output and recurse. Each comment also notes the failure must not abort the surrounding flush/sweep/eviction.
- No control-flow change; observability only.

## 0.3.5

**Fixes (audit):**
- `RpcOtelMetrics`: a single instance is shared by both the server interceptor (`OtelRpcInterceptor`) and the client interceptor (`OtelRpcClientInterceptor`) through the common `OtelRpcInterceptorBase.recordCall` flow. The instrument names were hardcoded to `rpc.server.requests` / `rpc.server.duration`, so client-side calls were recorded under the server namespace — a violation of the OTel RPC semantic conventions (client metrics must be `rpc.client.*`). `RpcOtelMetrics` now creates both instrument sets (`rpc.server.requests`/`rpc.server.duration` and `rpc.client.requests`/`rpc.client.duration`); `recordCall` takes a new `RpcMetricSide side` parameter (default `RpcMetricSide.server`, backward compatible) and routes the measurement to the matching instruments. Each interceptor reports its own side via a new `OtelRpcInterceptorBase.metricSide` getter (server -> `RpcMetricSide.server`, client -> `RpcMetricSide.client`), mirroring the `SpanKind` it already uses. Added a regression test (`a6_client_server_metric_namespace_test.dart`) asserting a server call lands only in `rpc.server.*`, a client call only in `rpc.client.*`, and a shared instance keeps the two sides separate.

## 0.3.4

**Refactor (no behavior change):**
- `OtelRpcInterceptor` (server) and `OtelRpcClientInterceptor` (client) were ~95% identical. Extracted the shared flow into a new `OtelRpcInterceptorBase` (`lib/src/interceptor/otel_rpc_interceptor_base.dart`): it holds the `tracer`/`metrics` fields, the four `intercept*` methods, and the span finishing/stream-wrapping helpers (`_finish`, `_finishWithError`, `_wrapWithSpan`). Each subclass now implements only `startSpan` — the single point of difference (server extracts the W3C parent context, uses `SpanKind.server`, and adds `rpc.trace_id`; client injects the context, uses `SpanKind.client`, and calls `updateContext`). Public API, const constructors, and barrel exports are unchanged. Future fixes to the shared flow now apply once instead of twice.

## 0.3.3

**Fixes (audit):**
- `LogControllerOtelOutput`: the default `spanTtl` was `30ms`, which made the periodic sweep force-end ANY log-span still doing work after 30ms — truncating normal traces (exported with a ~30ms duration, missing the final status/attributes/error, and silently dropping the real end record). The TTL is now a leak-guard, not a duration cap: the default is `5 minutes` (sweep interval `30s`). `maxOpenSpans` LRU eviction remains the primary bound. Both stay configurable. Added a regression test asserting a span legitimately open longer than the sweep interval is NOT force-ended while live and carries its real duration on its real end record.
- Stream-wrapping span end (`_wrapWithSpan` in both server and client interceptors): the source is listened with `cancelOnError: false`, so an `onError` is NOT terminal — a server/bidi stream may emit a non-fatal item error and then keep emitting or complete normally. Previously the span was ended (and marked errored) on the FIRST error, dropping all later messages and the real completion. The span now ends on stream TERMINATION (`onDone` / `onCancel`) exactly once; each error is recorded on the span as an exception event as it arrives, and the last error sets the final error status. Added a regression test.

## 0.3.2

**Web / dart2js correctness:**
- Verified the full web-facing surface (both interceptors, `RpcOtelMetrics`, `RpcOtelPropagator`, `LogControllerOtelOutput`) compiles to JS and runs on the real web target: the audit suite passes under `-p chrome`. No `dart:io` is imported; stream wrapping uses an explicit `StreamController` with an `onCancel` hook (no `async*` generator), so subscription cancel propagates cleanly on dart2js.
- Added `test/web_smoke_test.dart` — a dart2js smoke that exercises the propagator inject/extract round-trip, the status-name/error-code tables, and the `Int64` nanosecond timestamp conversion. It runs green on `vm`, `chrome`, and `node`.
- The audit suite is now tagged `@TestOn('vm || chrome')`: it builds a real opentelemetry SDK tracer whose `IdGenerator` calls `Random.secure()`, which is unavailable under the `node` test platform (an environment limitation, not a package bug). This keeps `dart test -p node test/` green.
- Documented the dart2js timestamp caveat in `LogControllerOtelOutput._toInt64`: `DateTime.microsecondsSinceEpoch` has only millisecond resolution on the web, so span timestamps round to the nearest millisecond there. Values remain valid nanosecond epochs with preserved ordering — only precision is reduced.

**Metrics (#6 — OTel histogram):**
- Still blocked upstream. Checked `opentelemetry` up to the latest published version (0.18.11); `Meter` exposes only `createCounter` (no Histogram / UpDownCounter). `rpc.server.duration` therefore remains a sum counter; the `TODO(#6)` now records the version surveyed.

## 0.3.1

**Fixes (audit):**
- The RPC span is now installed as the ambient OTel `Context.current` for the duration of the handler, so spans and log-spans created inside the handler are correctly parented under the RPC span (server and client interceptors).
- `rpc.grpc.status_code` is now emitted as the numeric semconv integer (0..16) on both spans and metrics; the human-readable name moved to the non-semconv key `rpc.grpc.status`.
- `LogControllerOtelOutput` no longer leaks un-ended spans: the open-span map is now bounded with LRU + TTL eviction (configurable `maxOpenSpans`, `spanTtl`, `sweepInterval`).
- Measured call duration is now recorded via the `rpc.server.duration` counter (was collected but discarded). TODO: switch to a histogram once the OTel API exposes one.
- Added a test suite (the package previously shipped with none).

## 0.3.0

- **`LogControllerOtelOutput`** — a `LogOutput` that mirrors every
  `LogController` span/event into OpenTelemetry. `LogSpanStart` opens an OTel
  span with the same timestamp; nested `LogScope.startSpan(...)` calls become
  child OTel spans (relies on the new `LogSpanStart.parentSpanId` field in
  `rpc_dart` core). `LogEvent`s with a `spanId` become `span.addEvent(...)`;
  standalone events emit a single-shot span. Provide `rootContextProvider:
  () => Context.current` to nest log-spans under the active RPC span.
- **Note:** depends on `rpc_dart` ≥ the release that ships
  `LogSpanStart.parentSpanId` / `traceId`. Bridge silently degrades to flat
  spans on older versions (only direct children of the root context).
- **Metrics now follow OpenTelemetry RPC semantic conventions.**
  - New: single counter `rpc.server.requests` with `rpc.system`, `rpc.service`,
    `rpc.method`, and `rpc.grpc.status_code` (uppercase canonical name)
    attributes — both success and error increments share the same counter.
  - Removed: `rpc_dart.calls.total` and `rpc_dart.errors.total`.
  - `RpcOtelMetrics.recordCall` now requires `statusCode:` and `duration:`.
    `recordError` was removed (status code label distinguishes the outcome).
- `OtelRpcInterceptor` now sets `rpc.grpc.status_code` as a span attribute
  and derives the code from `RpcStatusException` when an error is thrown.
- New `OtelRpcClientInterceptor` — client-side counterpart that creates a
  `SpanKind.client` span and injects W3C `traceparent`/`tracestate` into the
  outgoing `RpcContext`. Cross-service traces now stitch automatically.
- New `rpcGrpcStatusName(code)` helper exposing the canonical gRPC status
  names used for the `rpc.grpc.status_code` label.

## 0.2.0

- Updated to `rpc_dart: ^3.0.0`.
- `OtelRpcInterceptor`: adapted to new resilience interceptor interfaces in core.

## 0.1.0

- Initial release: `OtelRpcInterceptor` for OpenTelemetry spans with W3C trace context propagation.
- `RpcOtelMetrics` for RPC call metrics via OpenTelemetry.
