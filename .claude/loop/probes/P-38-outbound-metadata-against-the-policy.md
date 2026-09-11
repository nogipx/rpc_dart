---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/outbound_metadata_unvalidated.dart
round: 340 — the validating round
commit: d5fe8441
paths: [packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-38 — does a transport refuse outbound metadata its own policy forbids

Sends metadata that violates a configured `RpcSecurityPolicy` through
`IRpcTransport.sendMetadata` on two transports side by side, and reports what
each did. The shared-layer arm is `RpcChannelTransport.pair()` — the same class
websocket, wasm and isolate run on — so the comparison is against the behaviour
four of five transports already have.

Add a case to the `cases` map. The policy is deliberately tight but must stay
above what an ordinary request carries; see Control.

## Measures

Whether `sendMetadata` throws locally, and — the part that decides severity —
whether an ordinary call on the same connection still works before and after.

## Control

The shared-layer arm is the control: same input, same policy, a transport that
has always had the check.

```
                            shared layer                       http2 (before)
64 headers (max 32)         ArgumentError: Too many...         ACCEPTED
value 200 chars (max 64)    ArgumentError: Invalid value...    ACCEPTED
header name with a space    ArgumentError: Invalid name...     ACCEPTED

                                                               http2 (after)
                                                               identical text
                                                               to the shared arm
```

A clean call before and after each violation returns `ok(x)` in every arm, which
is what bounds the blast radius to one stream.

## The trap in the policy value

A first pass used `maxHeaders: 4`. That is BELOW what an ordinary request
carries, so the peer refused every call including the control — and the output
read exactly as though the violating frame had poisoned the connection. The
"clean call BEFORE" arm is what exposed it. **A limit chosen to be violated must
still admit the control.**
