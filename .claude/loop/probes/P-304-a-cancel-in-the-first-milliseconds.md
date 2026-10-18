---
file: packages/transport/rpc_dart_http/.dart_tool/probe/r821_early_cancel.dart
round: 821
commit: 16b052a6
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline_dispatch.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/transport/rpc_dart_http/lib/src/peer_watch.dart]
status: stale (526c8d52)
promoted: — (a CLEAN measurement)
---

# P-304 — a cancel in the first milliseconds

## Measures

`r821_early_cancel.dart <channel|http> <delay ms> <runs>`: one caller
endpoint (`RpcChannelTransport.pair()`, or `RpcHttpCallerTransport` against
an `RpcHttpServer`) makes `runs` unary calls 5 ms apart, each cancelling its
token `delay` ms after the start. The handler runs 5 s, polling its token
every 20 ms. Counts handlers that started, saw the cancel, or ran to
completion (a lost cancel).

```
  transport  delay      entered  saw cancel  completed
  channel    none       40       0           40   (control)
  channel    1-50 ms    40       40          0
  http       none       20       0           20   (control)
  http       1 ms       0        0           0    (aborted before the server read it)
  http       3 ms       17       17          0
  http       10-500 ms  19-20    all         0
```

The first http run used a 1 s handler and showed every cancel lost: macOS
sees a peer's close about 2.1 s late (P-295), so a handler shorter than that
always finishes first. The 5 s handler takes that delay out.

## Control

No cancel: every handler runs to completion on both transports.
