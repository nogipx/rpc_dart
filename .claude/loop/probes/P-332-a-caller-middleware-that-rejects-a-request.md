---
file: packages/core/rpc_dart/.dart_tool/probe/r865_caller_request_middleware_throws.dart
round: 865
commit: 01ec5654
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
status: stale (526c8d52)
promoted: no — a CLEAN measurement
---

# P-332 — a caller middleware that rejects a request

`fvm dart run <file> <bad|control>` from the repo root. An
`RpcChannelTransport` pair; a caller with one middleware whose
`processRequest` throws on `r1`, sending r0..r3 on a client-stream and a
bidi call. The handlers record every request they read and how their
request stream ended. Prints both sides.

## Measures

Whether a request the caller's own middleware rejects ends the upload
there, or the server reads past a gap.

## Control

`control`: both calls OK, the handler read r0, r1, r2, r3 and DONE.
