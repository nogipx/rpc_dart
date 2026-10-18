---
file: packages/core/rpc_dart/.dart_tool/probe/r861_decode_failure_reaches_server.dart
round: 861
commit: ef063cb9
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/caller.dart]
status: stale (526c8d52)
promoted: packages/core/rpc_dart/test/endpoint/a_server_stream_that_fails_locally_tells_the_server_test.dart
---

# P-328 — does a local decode failure reach the server?

`fvm dart run <file> <server|bidi> <decode|control>` from the repo root. An
`RpcChannelTransport` pair; a server-stream or bidi handler that yields
every 10 ms forever and stops when its context is cancelled. The caller's
response codec throws on the third value, and the consumer listens with
`onError` (no `cancelOnError`). Prints what the caller saw, how many items
the handler produced in the second after, and whether it saw its cancel.
Arm `control`: the consumer cancels its subscription after two items. An
http2 copy lives at `rpc_dart_http2/.dart_tool/probe/` under the same name.

## Measures

Whether the server's handler stops when the caller's call ends on a
failure only the caller sees.

## Control

`control` on both shapes: 0 more, cancel seen.
