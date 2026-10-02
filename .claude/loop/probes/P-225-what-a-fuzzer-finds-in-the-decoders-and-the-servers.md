---
file: packages/core/rpc_dart/.dart_tool/probe/fuzz_decoders.dart
round: 639
commit: 2c540e05
paths: [packages/core/rpc_dart/lib/src/codec/special_cbor.dart, packages/core/rpc_dart/lib/src/core/parser.dart, packages/core/rpc_dart/lib/src/core/channel_frame.dart, packages/core/rpc_dart/lib/src/core/error_details.dart, packages/core/rpc_dart/lib/src/core/compression.dart, packages/core/rpc_dart/lib/src/core/metadata.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart]
status: valid (round 639)
---

# P-225 — what a fuzzer finds in the decoders and the servers

## Why it exists

Both critical defects of the 2026-10-02 audit (round 624's crash, round 625's
CBOR corruption) sat in code that parses a peer's bytes, after 600 rounds that
read and measured it. A fuzzer is the instrument for that class, and the
project had none.

## The harness

Four files, all `fvm dart run <file> [count] [seed]`:

- `packages/core/rpc_dart/.dart_tool/probe/fuzz_decoders.dart` — mutated valid
  encodings and noise into every decoder run on peer bytes: CBOR (`decode`,
  `decodeUnsafe`, through `RpcCodec`), the gRPC parser under random chunking,
  `RpcChannelFrame.decode`/`decodeAll`, `decodeRpcStatus`, `fromTrailer`, gzip,
  `decodeGrpcMessage`, `parseGrpcTimeout`. Records exception TYPES, any `Error`,
  inputs over 100 ms.
- `.../fuzz_server.dart` — a fake `IRpcChannel` feeds 40 structured or mutated
  frames (random streams, methods, end-of-stream, timeouts, cancels, two
  messages, bare prefixes, compressed flags) into a server transport and
  responder, then one valid unary call. Defect: anything in the zone, an
  unanswered call on an open connection, responders left after close. Chunks
  that do not split into whole frames are excluded: they desync the peer's own
  byte stream.
- `.../fuzz_client.dart` — the mirror: a hostile server answers all four call
  shapes, each with a 1 s deadline. Defect: anything in the zone, a call not
  done in 3 s.
- `packages/transport/rpc_dart_websocket/.dart_tool/probe/fuzz_ws_server.dart` —
  hostile raw sockets against a real `RpcWebSocketServer`: handshake variants
  (methods, versions, keys, repeated headers, long headers, cut handshakes),
  WebSocket frames (masks, control frames, fragmentation, junk opcodes, RSV
  bits, lying lengths), written in one go, after a pause, or byte by byte; a
  well-formed client checked every ten attacks. `[compression on|off]`.

## The numbers (round 639)

```
decoders, 100 000 inputs per target, 11 targets   only FormatException /
                                                  RpcStatusException / RpcFrameException;
                                                  no Error, nothing over 100 ms
server, 300 + 3000 sessions                       every valid call answered, 0 in the zone
client, 150 sessions                              no call hung, 0 in the zone
websocket, compression off, 300 + 2000 attacks    every check served, 0 in the zone
websocket, compression on, 300 attacks            19 uncaught HttpException: a repeated
                                                  Sec-WebSocket-Key -- round 639
  after the fix, 1000 attacks                     every check served, 0 in the zone
```

## Measures

Whether a peer's bytes can crash, hang or wedge an rpc_dart process.

## Control

Each harness's well-formed path: the seeds decode, the valid call is answered,
the clean client is served.
