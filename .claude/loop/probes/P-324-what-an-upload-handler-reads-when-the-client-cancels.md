---
file: packages/core/rpc_dart/.dart_tool/probe/r856_cancelled_upload_handler.dart
round: 856
commit: 703eb810
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor_responder.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: stale (526c8d52)
promoted: no — a CLEAN arm; the http2 half is promoted through P-323
---

# P-324 — what an upload handler reads when the client cancels

`fvm dart run <file>` from the repo root. An `RpcChannelTransport` pair; a
client-stream (`collect`) and a bidi (`chat`) handler each read their whole
request stream with `toList()` and record DONE with the items, or the
error. The client sends two messages, then either closes its request
stream (`finish`) or cancels its token (`cancel`).

## Measures

Whether a handler reads a cancelled upload as an error or as a complete
request stream.

## Control

`finish`: DONE with [a, b] on both shapes.
