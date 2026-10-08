---
file: packages/core/rpc_dart_opentelemetry/.dart_tool/probe/r725_unknown_methods_reach_telemetry.dart
round: 725
commit: 472dd6af
paths: [packages/core/rpc_dart_opentelemetry/lib/src/interceptor/**, packages/core/rpc_dart_opentelemetry/lib/src/metrics/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-239 — do calls to unregistered methods reach the OTel interceptor?

A memory pair with `OtelRpcInterceptor` on the responder and an in-memory
span exporter. The run makes 100 calls to the one registered method, then
200 calls to random service and method names. Run with `melos exec
--scope=rpc_dart_opentelemetry -- fvm dart run
.dart_tool/probe/r725_unknown_methods_reach_telemetry.dart`.

## Measures

Spans exported for each group, and the number of distinct span names.

## Control

The registered-method arm, which shows the instrument emitting:

```
  registered method x100      100 spans
  unregistered names x200       0 spans
  distinct span names           1
```
