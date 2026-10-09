---
file: packages/core/rpc_dart/.dart_tool/probe/warnings_per_peer_call.dart
round: 790
commit: 713ca944
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/**]
status: valid
---

# P-284 — log records per malformed call

## Measures

A responder over `RpcChannelTransport.fromChannel` with its own
`LogController` (min level warning); 200 calls on one connection of each
shape (`u`, `s`, `c`, `b`), each sending METADATA, then one of: an empty DATA
frame, a 5-byte truncated prefix, nothing, a complete message; then a
half-close. Plus 200 calls to an unregistered method. Counts the records at
warning or above, grouped by message with digits masked.

Round 790, before:

```
  shape  empty   truncated   noData   complete
  u      200     200         200      0
  s      0       200 (error) 0        0
  c      0       0           0        0
  b      0       0           0        0
  unregistered method: 0
```

After: 0 in every cell.

## Control

`complete` on every shape and the unregistered method: the same peer, the
same 200 calls, the same logger; only the request is well-formed (or refused
by the pipeline's once-guarded path). 0 records. And client-stream and bidi
under the same malformed inputs: 0.
