---
status: open
round: — (not re-measured by a round; measured by the conformance matrix)
commit: 91ec33ea
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: none — packages/test/rpc_dart_conformance/test/i5_resources_return_test.dart, cell "websocket | close after silent"
reason: bench — a KNOWN FAILING cell of I-5; severity S1 (a close that never ends)
rank: 1
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
