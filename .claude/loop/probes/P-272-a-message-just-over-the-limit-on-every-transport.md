---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r772_over_the_limit_parity.dart
round: 772
commit: ca0e7cfe
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_isolate/lib/**]
status: valid
---

# P-272 — a message just over the limit on every transport

## Measures

Both ends at `maxMessageLengthBytes: 64 KiB`, SIZE 70000. Per transport,
four rows (unary big request, unary big response, server-stream big
response, client-stream big request): the oversized call's outcome, then
a small unary call on the same connection. `r772_pair_over_limit.dart` in
`packages/core/rpc_dart/.dart_tool/probe/` runs the unary rows on the core
pair and on a framed channel.

Small: 64 KiB instead of the 16 MiB default, so a run is seconds and
megabytes.

## Control

The follow-up small call: it shows whether the refusal stayed with the
call or took the connection.
