---
round: 789
commit: 272098cf
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_http2/lib/**]
scope: round 787's class (a unary request that completes no message, then a half-close) on the HTTP/1.1 and HTTP/2 responders, and its mirror on the unary caller
---

# C-71 — an empty unary payload on every other path

Round 787 fixed the channel transports (websocket, isolate, in-memory, wasm
all run `RpcChannelTransport`). The other paths, measured:

```
  path                         empty     truncated   complete   none
  HTTP/1.1 RpcHttpServer       3         3           0          -
  HTTP/2   RpcHttp2Server      3 (50/50) 3 (50/50)   0 (50/50)  3 (50/50)
  HTTP/2, round 787 fix OFF    3 (50/50) 3 (50/50)   0 (50/50)  3 (50/50)
```

Nothing held on any. HTTP/1.1 delivers an empty body as no data message at
all, so the pipeline's "closed without payload" refusal answers. HTTP/2
answers with or without the fix: its empty DATA frame reaches the pipeline
with the half-close, not as a separate frame after it.

The caller mirror (a server answering a unary call with an empty DATA frame,
a truncated prefix or nothing, then grpc-status 0): INTERNAL "The peer
completed the call with no response payload" in each. Without a trailer
every arm waits, the complete one included: a call is not over until its
status, and a deadline is what bounds a silent server.

Probes: `rpc_dart_http/.dart_tool/probe/empty_unary_body.dart`,
`rpc_dart_http2/.dart_tool/probe/empty_unary_data.dart`,
`rpc_dart/.dart_tool/probe/caller_empty_response.dart`.

## Control

HTTP/2 with round 787's fix switched off, the same answers: the class does
not reach it. On the caller, the `complete` arm: with a trailer it succeeds,
without one it waits like the rest, so the wait is the missing status and
not the empty payload.
