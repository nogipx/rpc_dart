---
status: closed (round 800)
round: — (not re-measured by a round; measured by the conformance matrix)
commit: 91ec33ea
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: none — packages/test/rpc_dart_conformance/test/i5_resources_return_test.dart, cell "websocket | close after silent"
reason: "FIXED in round 800: the close no longer awaits the sink of a channel whose upgrade is unanswered; 20 s+ -> 5 ms, the matrix cell un-marked"
---

# B-277 — the websocket caller's close never completes against a silent peer

Found by the conformance matrix (I-5, resources return), not by a round.

When the peer accepts TCP and never answers the WebSocket handshake,
`RpcWebSocketCallerTransport.close()` does not complete. A probe found it
still pending at 40 s. `endpoint.close()` returns only because the endpoint
abandons the transport after its own 5 s.

```
the caller transport did not close within 3 s
```

Siblings under the same peer behaviour close in time: channel, http, http2.
The witness is the matrix cell; remove its `_knownFailing` entry and run
`fvm dart test test/i5_resources_return_test.dart -N "websocket | close after silent"`
in packages/test/rpc_dart_conformance.

## Owner decision

—
