---
file: packages/core/rpc_dart/.dart_tool/probe/r857_refused_upload_core.dart
round: 857
commit: 98ba93a5
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor_responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart]
status: valid
promoted: no — the reference column for P-323; the http2 half is promoted there
---

# P-325 — what core answers a request refused mid-stream

`fvm dart run <file> [cut-only]` from the repo root. A raw channel into an
`RpcResponderEndpoint` (policy `maxMessageLengthBytes: 1024`); four methods
(unary, server, client, bidi). The client sends one whole message and then
a tail (`whole`, `over-limit` prefix, `cut` 3 bytes, `undecodable`,
`compressed` flag), in one chunk or in three, then END_STREAM. `cut-only`
sends only a frame cut at 7 bytes. Prints the grpc-status the responder
sends and what each handler read (DONE with items, or the error).

## Measures

The status core answers each malformed request with, per shape, and
whether an upload handler reads it as complete.

## Control

`whole` on client and bidi: grpc=0, DONE [x, x].
