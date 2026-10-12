---
file: packages/core/rpc_dart/.dart_tool/probe/r854_undecodable_log_volume.dart
round: 854
commit: 51ef9138
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor_caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart]
status: valid
promoted: packages/core/rpc_dart/test/streams/a_hostile_response_is_logged_once_test.dart
---

# P-321 — log records per hostile response chunk

`fvm dart run <file> <n> <server|unary|bidi> [more]` from the repo root. A
caller `RpcChannelTransport` over a fake channel, with a `LogController` at
debug. The "server" answers one DATA chunk of `n` 2-byte frames the JSON
codec cannot decode (`{{`), with `more` a second chunk of `n` decodable
ones, then an OK trailer. Prints what the consumer saw and the caller's log
records by level.

Arms beside it: `r854_responder_log_volume.dart` (the responder side, a bidi
method fed the same chunk, then END_STREAM and `n` more) and
`rpc_dart_http2/.dart_tool/probe/r854_http2_log_volume.dart` (a raw h2 peer).

## Measures

Log records the caller writes for one hostile response, against the one
error its consumer sees.

## Control

`n = 1`: 2 error records (the decode failure and the call's own). Unary at
`n = 1000`: also 2, it stops at the first message.
