---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/log_records_per_hostile_input.dart
round: 793
commit: adf09a2e
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/transport/rpc_dart_websocket/lib/**]
status: valid
---

# P-286 — log records per hostile websocket input

## Measures

`RpcWebSocketServer.createWithContracts` over `rpcWebSocketConnections`, a
fresh server and `LogController` per input; a plain dart:io `WebSocket`
client repeats one cheap input 100 times on one socket. Counts the server's
records at warning or above, with level, error type and message.

Round 793, before:

```
  input                  records   kind
  text frame             100       error  RpcWebSocketNonBinaryFrame (advisory)
  binary garbage         1         error  RpcFrameException, socket closed 4413
  unknown method         0
  bad content-type       0
  too many headers       100       error  _OneStreamViolation (advisory)
  cancel unknown id      0
  data for finished id   0
  valid call (control)   0
```

After: text frame 1 warning, too many headers 1 warning, binary garbage 1
error (unchanged), every other row 0.

## Control

The valid-call row, and the rows whose inputs are refused through paths
that already log once: 0. And binary garbage, a non-advisory failure that
ends the connection: 1 error before and after.
