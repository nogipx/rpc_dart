---
status: open
round: — (not re-measured by a round; measured by the conformance matrix)
commit: 91ec33ea
paths: [packages/core/rpc_dart/lib/src/rpc/transports/**]
probe: none — packages/test/rpc_dart_conformance/test/i7_one_failure_one_status_test.dart, the 4 "channel | ... oversizeRequest" cells
reason: bench — KNOWN FAILING cells of I-7; severity S2 (a status a caller branches on)
rank: 4
---

# B-281 — an oversized request on a channel ends UNAVAILABLE, not RESOURCE_EXHAUSTED

Found by the conformance matrix (I-7, one failure, one status).

```
channel, all 4 shapes:
status 14 "The stream closed before the peer sent a status", expected 8
http, http2, websocket, isolate: 8
core's own RpcChannelTransport.pair(): 14, the same
```

Only a channel with a close code (websocket) can tell the caller its request
was too large; the bare channel closes the stream and the caller reports the
closure. A caller that retries UNAVAILABLE retries a request that can never
fit.

## Owner decision

—
