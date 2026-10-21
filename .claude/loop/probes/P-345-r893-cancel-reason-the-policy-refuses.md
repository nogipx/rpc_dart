---
file: packages/core/rpc_dart/.dart_tool/probe/r893_cancel_reason/probe.dart
round: 893
commit: 1b07ee3b
paths: [packages/core/rpc_dart/lib/src/core/trailers.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor_caller.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline_dispatch.dart]
status: valid
promoted: packages/core/rpc_dart/test/streams/a_cancel_reason_in_any_language_reaches_the_server_test.dart
---

# P-345 — r893 cancel reason the policy refuses

## Measures

Whether a server-stream handler on an in-memory pair is cancelled within 1 s
after the caller cancels its context token with a given reason. Arms: a
non-ASCII reason ("Пользователь отменил") and a 10000-character one. Before:
both "still running at 1 s". After: both "saw the cancel".

## Control

The same call cancelled with "user cancelled": "saw the cancel" before and
after.
