---
status: awaiting owner
round: — (not re-measured by a round; measured by the conformance matrix)
commit: 91ec33ea
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart, packages/core/rpc_dart/lib/src/rpc/transports/**, packages/transport/rpc_dart_http/lib/**]
probe: none — packages/test/rpc_dart_conformance/test/i9_reconnect_is_honest_test.dart, cells "channel | ..." and "http | ..." of "never Online before the peer speaks"
reason: owner decision — HTTP/1.1 has no connection to be ready; whether I-9's second half applies to http and to a bare channel is the owner's
rank: 13
---

# B-282 — channel and http read Online before the peer has spoken

Found by the conformance matrix (I-9, reconnect is honest).

Against a peer that never sends a byte, `RpcClientConnection` goes Connecting
then Online on channel and on http. Neither transport implements
`IRpcTransportReadiness`, so the connection reports Online as soon as the
transport is built. http2, websocket and isolate wait for the peer.

**The question for the owner:** for http, Online-on-build may be the honest
answer (there is no connection until a request); for a channel it is a
missing readiness signal. Which of the two does I-9 cover?

## Owner decision

—
