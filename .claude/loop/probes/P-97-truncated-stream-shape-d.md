---
file: packages/core/rpc_dart/.dart_tool/probe/truncated_stream_shape_d.dart
round: 429
commit: f1cf6a0a
paths: [packages/core/rpc_dart/lib/src/rpc/transports/**, packages/core/rpc_dart/lib/src/rpc/streams/**, packages/core/rpc_dart/lib/src/endpoint/**]
status: valid
---

# P-97 — how a server stream ENDS when the peer vanishes mid-stream

`fvm dart run packages/core/rpc_dart/.dart_tool/probe/truncated_stream_shape_d.dart`.

Three arms over `RpcChannelTransport.pair()`. A server-stream handler yields two
payloads and then parks; the peer's side of the channel is closed with no status
trailer. For another ending, change what `_arm` does instead of `server.close()`.

## Measures

How the CALLER's subscription terminated: items delivered, whether an error
arrived, and whether `onDone` ran with no error before it. The interesting
value is the combination — `items=2, NO ERROR, endedClean=true` is a truncated
response indistinguishable from a complete one.

## Control

The third arm calls a handler that ends properly, so the probe has to report
`NO ERROR` for something. Without it, three arms all saying "error" would be
equally consistent with an instrument that cannot say anything else.

```
d  delivered-then-cut    items=2  error=RpcStatusException  endedClean=false
c  cut-before-delivery   items=0  error=RpcStatusException  endedClean=false
CONTROL complete         items=2  NO ERROR                  endedClean=true
```

B-09 item 3 expected `d` to read `items=2, NO ERROR` — the reading carried over
from private memory. It does not, and the control is what makes that a
measurement rather than an instrument that only knows one answer.
