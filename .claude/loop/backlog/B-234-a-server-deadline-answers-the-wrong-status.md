---
status: open
round: 625
commit: ff258470
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart]
probe: none — audit probe `packages/core/rpc_dart/.dart_tool/probe/correct_wire_deadline_test.dart`, not yet registered
reason: "bench — when the server's own deadline fires on a cooperative handler, unary answers CANCELLED instead of DEADLINE_EXCEEDED and server-stream usually sends no status at all"
---

# B-234 — a server deadline answers the wrong status

Found by the independent audit of 2026-10-02 (protocol), reproduced before
filing. Related to B-100 (http1, uncooperative handler), a different path.

## The shape

`_onDeadlineExceeded` cancels the handler's token with reason "deadline
exceeded" and sends no trailer of its own. A handler that does what the guide
says (`throwIfCancelled()` in its loop) throws `RpcCancelledException`, which is
sent as CANCELLED. On server-stream the stream is usually never ended.

## Measured

A raw client sends `grpc-timeout: 200m`; the handler checks the token every
20 ms and runs ~2 s:

```
unary x6          status 1 "deadline exceeded" at 203-224 ms
server-stream x6  9-10 messages, then no status within 6 s (4 of 6); run alone once: status 1
control 10S       unary status 0 at ~2.3 s, server-stream 100 messages + status 0
```

The rpc_dart caller hides it: its own timer fires first. A foreign client or a
proxy gets the wrong code, or a stream that never ends.

## Owner decision

2026-10-02: the server answers DEADLINE_EXCEEDED, and the rpc_dart caller maps
a status-4 trailer to `RpcDeadlineExceededException`, so the race between the
two cannot change the exception type. Measured first: an rpc_dart caller sees
`DeadlineExceeded(4)` 40/40 on unary and server-stream today, its own timer
winning; only foreign clients see the wrong status.
