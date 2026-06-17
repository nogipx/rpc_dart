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
