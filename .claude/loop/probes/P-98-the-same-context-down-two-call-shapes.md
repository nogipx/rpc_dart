---
file: packages/core/rpc_dart/.dart_tool/probe/ping_reserved_headers.dart
round: 444
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/core/rpc_headers.dart]
status: valid
---

# P-98 — one RpcContext sent down two call shapes

`fvm dart run packages/core/rpc_dart/.dart_tool/probe/ping_reserved_headers.dart`
from `packages/core/rpc_dart`.

Seven arms over `RpcChannelTransport` on a `RpcFrameMultiplexedChannel.pair()`,
each a caller context carrying one key that `RpcHeaders.reserved` names. For
another key, add it to one of the context literals; for another shape, add a
`_arm` line calling `unary`/`ping` with the same context.

## Measures

What the peer answered, on the library's own responder: the grpc-status the call
ended with, and for the unary arms what the handler saw in `context.headers`.
The interesting value is the DIFFERENCE between two arms holding the same
context, because the call shape is then the only variable.

## Control

Two of them, which is what makes the asymmetry readable. A2/A5 send the same
context down the sibling shape, whose merge site has the filter; A3 sends a
clean context down the shape under test. A1 differing from BOTH is the finding —
one control alone would leave "ping is just broken" and "the header is the
cause" indistinguishable.

```
A1 ping    content-type : status=3  Invalid content-type for gRPC   <- the defect
A2 unary   content-type : OK  timeout=null mark=carried             <- control: sibling shape
A3 ping    clean        : OK  status=0                              <- control: clean context
A4 ping    grpc-timeout : OK  status=0
A5 unary   grpc-timeout : OK  timeout=null mark=carried
A6 ping    x-client-canc: OK  status=0
A7 ping    window-update: OK  status=0
```

A6 and A7 are what BOUNDS the severity, and they are measurements rather than
reassurance: the two reserved keys a peer ACTS on do travel on the ping frame
(the canary shows them arriving) and change nothing, because both consumers gate
on `methodPath == null` and a ping frame carries one.

After the fix A1 reads `OK status=0` and no other arm moves.
