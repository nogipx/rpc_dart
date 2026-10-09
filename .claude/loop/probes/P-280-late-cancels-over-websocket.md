---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/rapid_cancel_ws.dart
round: 786
commit: a7f919ce
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
status: valid
---

# P-280 — late cancels over websocket

## Measures

`RpcWebSocketServer.createWithContracts` over `rpcWebSocketConnections`, a
real socket, `maxActiveStreams: 4`, `maxConcurrentHandlers` from argv[2]
(absent = null). One unary handler that ignores its token and sleeps
300 ms, counting handlers entered and the peak running at once. The client
fires 200 calls over one connection. Arms (argv[0]): `normal` all at once;
`cancel` each token cancelled in the next microtask; `paced` one call every
2 ms; `late` the same pacing, each token cancelled 10 ms after its call.

```
  arm      maxConcurrentHandlers   entered   peak running
  normal   null                    4         4
  cancel   null                    4         4
  paced    null                    12        4
  late     null                    191-193   92-93
  late     4                       12        4
```

## Control

`paced`: the same arrivals as `late` without the cancel; peak 4. And `late`
with `maxConcurrentHandlers: 4`: the same attack against the bound the
`maxActiveStreams` doc points to; peak 4.
