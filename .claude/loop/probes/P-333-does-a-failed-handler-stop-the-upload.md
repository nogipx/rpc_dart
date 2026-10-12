---
file: packages/core/rpc_dart/.dart_tool/probe/r867_server_fails_mid_upload.dart
round: 867
commit: b18da1bb
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart]
status: valid
promoted: no — a CLEAN measurement
---

# P-333 — does a failed handler stop the upload?

`fvm dart run <file> <throw|control|reads>` from the repo root. An
`RpcChannelTransport` pair; a client-stream and a bidi call whose request
producer yields every 10 ms forever. `throw`: the handler throws ABORTED
after two requests; `control`: it answers after two; `reads`: the
client-stream handler reads forever. Prints how each call ended and how
many requests the producer was asked for in the second after. The pull
counter is shared by both calls, so the bidi line of the `reads` arm also
counts the still-running client-stream producer.

## Measures

Whether the caller stops pulling its request producer once the server has
ended the call.

## Control

`reads`, client-stream: the call does not end and the producer is pulled
75 more times in 1 s.
