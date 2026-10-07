---
status: open (round 711)
round: 711
commit: 45ee7b15
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart]
probe: .dart_tool/probe/audit_h2/depth.dart
reason: "measured — found by the http2 audit; the owner's earlier trade, now with a count"
---

# B-261 — h2 uploads meet the depth without credit

## Seen

HTTP/2 has no message credit, and the responder keeps reading so its own byte
window never throttles the sender (the owner's earlier choice: a handler that
stops consuming ends its own call rather than wedging the connection). The
depth bound then ends any client-stream or bidi call more than
`maxBufferedMessagesPerStream` messages ahead of its handler:

```
30000 x 8-byte messages, handler awaits 1 ms every 20:
upload FAILED after consumed=8272: RESOURCE_EXHAUSTED (max: 8192 messages)
fast handler: 30000/30000
```

About 240 KB was in flight, far below the 4 MiB byte threshold the owner
accepted. Before round 709 the depth was 1024, so this is less likely now than
it was, not new.

## Why it matters

A real gRPC client streaming small messages to a handler with any per-message
latency fails. The policy doc says only a peer ignoring credit reaches the
depth, which is false on h2.

## What a round owes this

The owner's call: (a) no depth bound on h2 wire messages, bytes only, as the
accepted trade states; (b) pause reading for that stream past the depth, which
the earlier round rejected for the connection-window reason it records; (c)
leave and document.

## Owner decision

—
