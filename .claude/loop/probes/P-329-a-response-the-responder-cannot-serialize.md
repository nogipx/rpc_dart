---
file: packages/core/rpc_dart/.dart_tool/probe/r862_response_cannot_serialize.dart
round: 862
commit: 3714c700
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor_responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline_responders.dart]
status: stale (526c8d52)
promoted: packages/core/rpc_dart/test/streams/a_response_that_cannot_be_sent_ends_the_stream_test.dart
---

# P-329 — a response the responder cannot serialize

`fvm dart run <file> <bad|control>` from the repo root. An
`RpcChannelTransport` pair; a responder whose response codec throws on
`'bad'`. Unary and client-stream handlers return it; endless server-stream
and bidi handlers yield it second. Prints what each caller reads (the
streams up to four events) and what a streaming handler produced in the
0.5 s after. An http2 copy lives at `rpc_dart_http2/.dart_tool/probe/`
under the same name.

## Measures

Whether a response that cannot be put on the wire ends the call at that
point, or is skipped.

## Control

`control`: every value serializes; unary and client OK, the streams read
ok0, ok1, ok2, ok3.
