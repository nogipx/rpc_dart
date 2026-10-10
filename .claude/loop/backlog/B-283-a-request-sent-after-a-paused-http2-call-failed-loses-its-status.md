---
status: open
round: — (not re-measured by a round; measured by the lifecycle model)
commit: 4b49fce1
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/**, packages/core/rpc_dart/lib/src/rpc/streams/**]
probe: none — packages/test/rpc_dart_conformance/test/lifecycle_model_test.dart, cell "http2 | pinned send after the handler failed, response paused"
reason: bench — a KNOWN FAILING cell of the lifecycle model; severity S2 (the server's status is replaced)
rank: 5
---

# B-283 — a request sent after a paused http2 call failed loses the server's status

Found by the lifecycle model (random operation sequences, shrunk), not by a
round.

```
start c0 bidi fail delay=17 count=3 deadline=none open; pause c0; wait 52; send c0
expected the handler's ABORTED, got status 9:
RpcStatusException(9): Stream 3 not found. Send metadata first.
```

While the caller has the response paused, the server ends the call with
ABORTED. A request the caller then sends ends the call with an internal
FAILED_PRECONDITION, and ABORTED is never seen. Without the pause it passes.
Deterministic, 3 of 3. http, websocket, channel and isolate pass the same
sequence.

## Owner decision

—
