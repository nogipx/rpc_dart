---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/text_frame_blast_radius.dart
round: 353
commit: 8d81b9e7
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/src/rpc/transports/**]
status: valid
---

# P-45 — what one stray frame costs the calls already in flight

Parks two unary calls in a handler over a real `dart:io` WebSocket pair, then
has the server interleave one TEXT frame on the same socket. Point it at any
other channel-level report by changing what the server sends.

## Measures

Two things, both about the library rather than the probe: the outcome of each
of the two in-flight calls, and whether the transport is still open afterwards.

## Control

One variable: whether the text frame is sent at all. Same server, transport,
contract and timing in both arms.

```
arm          two in-flight calls
no text      ok, ok                        connection alive
text frame   RpcException, RpcException    connection alive   <- before
text frame   ok, ok                        connection alive   <- after
```

`connection alive` in both before-rows is the point, not an aside: the channel's
comment promised *"reported rather than fatal, so the connection stays usable"*
and the connection WAS usable. A bench that only asked about the connection —
which is what the channel-level suite asked — reads the before-state as correct.
Ask what the layer above does with the report.
