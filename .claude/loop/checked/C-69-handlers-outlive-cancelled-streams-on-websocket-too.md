---
round: 786
commit: a7f919ce
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
scope: [websocket, core] — cancel after dispatch, handler ignoring its token; extends C-32 (http2, reset before dispatch)
---

# C-69 — handlers outlive cancelled streams on websocket too

CVE-2023-44487's shape on the websocket transport, cancelled AFTER the
handler starts rather than before (C-32's case): 200 calls paced 2 ms apart,
each cancelled at 10 ms, against `maxActiveStreams: 4` and a handler that
ignores its token. 191 handlers ran, 93 at once. That is what the
`maxActiveStreams` doc says it does ("bounds live stream state, not running
handlers"), and `maxConcurrentHandlers: 4` bounds the same attack to 4
(P-280).

Not a defect: the residual is documented, and `maxConcurrentHandlers` is
null by default by a recorded choice ("the number is a capacity decision").
grpc-go answered the CVE by holding the stream quota until the handler
returns, by default; that is the comparison to bring if the default is ever
reconsidered.

Re-open if `maxConcurrentHandlers` stops being charged at dispatch, or if
the default changes.

## Control

`paced`, the same arrivals without the cancel: peak 4. `late` with the
bound set: peak 4.
