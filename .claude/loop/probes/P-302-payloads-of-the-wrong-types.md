---
file: packages/core/rpc_dart/.dart_tool/probe/r817_wrong_types.dart
round: 817
commit: 0b53e9ea
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor_responder.dart, packages/core/rpc_dart/lib/src/codec/codec.dart]
status: stale (526c8d52)
promoted: — (a CLEAN measurement)
---

# P-302 — payloads of the wrong types

## Measures

`RpcChannelTransport.pair()` (framed bytes; `memoryPair` is zero-copy and
never reaches a codec). The server registers unary, server-stream,
client-stream and bidi methods whose request codec is
`RpcCodec(_Right.fromJson)` with `json['n'] as int`. The caller sends the
same method a `_Sent` map through a codec with no decoder: valid CBOR, the
right shape, wrong types. Records the caller's status and message, and the
server's warning-and-above log records (a `LogController` stream).

```
  request {n: ...}   unary / ss / cs / bi                                 server records
  1 (control)        ok                                                   0
  'one'              13 "Request payload could not be decoded" (all four) 0
  missing            13, same                                             0
  [1, 2]             13, same                                             0
  {a: 1}             13, same                                             0
  reverse (unary): the server answers {n: 'one'}; caller gets 13
    "Response could not be decoded", 2 ERROR records in the caller's log
```

## Control

The right type: all four shapes answer, no record.
