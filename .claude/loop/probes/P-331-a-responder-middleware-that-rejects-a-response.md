---
file: packages/core/rpc_dart/.dart_tool/probe/r864_responder_middleware_throws.dart
round: 864
commit: 01ec5654
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline_responders.dart]
status: stale (526c8d52)
promoted: no — a CLEAN measurement
---

# P-331 — a responder middleware that rejects a response

`fvm dart run <file> <bad|control>` from the repo root. An
`RpcChannelTransport` pair; a responder with one middleware whose
`processResponse` throws on the value `ok1`. A unary handler returns
`ok1`; a server-stream and a bidi handler yield ok0..ok3. Prints what each
caller reads and how it ends.

## Measures

Whether a response the responder's own middleware rejects ends the call at
that point or is skipped.

## Control

`control` (the middleware passes everything): unary `OK ok1`; both streams
ok0, ok1, ok2, ok3, done.
