---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r723_deaf_reader_bidi.dart
round: 723
commit: 472dd6af
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/responder.dart]
status: valid
---

# P-238 — does an h2 bidi handler run ahead of a deaf reader?

A raw `package:http2` client sends `count` gRPC frames on one bidi call and
pauses its response stream, so it reads its socket but grants no h2 credit.
The handler yields 1 KiB per request. Run with `melos exec
--scope=rpc_dart_http2 -- fvm dart run .dart_tool/probe/r723_deaf_reader_bidi.dart
100000 deaf` (or `reads`).

## Measures

Responses the server handler produced once it stops.

## Control

A reading client, and `RpcHttp2OutgoingPump.add`'s pause wait disabled:

```
  arm                     produced
  reads                   100000
  deaf                        66
  deaf, wait ablated      100000
```

Round 724 added a resume after the sends. The handler's count after it is
how many requests the server held: 152508 of 400000, then `grpc-status 8`.

A deaf reader must stop at the h2 level, not the TCP level. A TCP-level stop
also starves the client of WINDOW_UPDATEs, and it stops sending.
