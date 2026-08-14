<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_opentelemetry

OpenTelemetry tracing, metrics and log export for `rpc_dart`.

- `OtelRpcInterceptor` — server-side interceptor: one span per call, W3C
  `traceparent` extracted from the incoming metadata.
- `OtelRpcClientInterceptor` — caller-side counterpart, injects `traceparent`
  so the trace continues across the RPC boundary.
- `RpcOtelPropagator` — W3C trace-context extract/inject over `RpcContext`
  headers.
- `RpcOtelMetrics` — call counters and duration instruments.
- `LogControllerOtelOutput` — a `LogOutput` that forwards the built-in logger's
  records to OTel.

## Usage

```dart
import 'package:rpc_dart_opentelemetry/rpc_dart_opentelemetry.dart';

responderEndpoint.addInterceptor(
  OtelRpcInterceptor(tracer: tracer, metrics: RpcOtelMetrics(meter: meter)),
);

callerEndpoint.addInterceptor(
  OtelRpcClientInterceptor(tracer: tracer),
);
```

Spans are named `<Service>/<Method>` and carry `rpc.system`, `rpc.service`,
`rpc.method` and `rpc.call_type` attributes.
