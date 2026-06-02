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
