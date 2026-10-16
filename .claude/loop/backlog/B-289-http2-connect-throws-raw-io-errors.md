---
status: closed (round 879)
release: breaking
round: 814
commit: 9e0e3d85
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: packages/transport/rpc_dart_websocket/.dart_tool/probe/r814_connect_failures.dart
reason: owner — the sibling of B-288, and changing a public method's thrown type is breaking; http2 is the owner's low priority
rank: 2
---

# B-289 — http2 connect throws raw io errors

P-300: `RpcHttp2CallerTransport.connect` to a refused port throws dart:io's
`OSError`/`SocketException`, where the websocket caller (after round 814) and
the http caller report UNAVAILABLE. A `shouldReconnect` that branches on
`RpcStatusException` sees a foreign type from this transport only.

Not measured: the TLS handshake failure from `secureConnect`, the proxy
CONNECT refusal (`_connectH2ViaProxy`) and the settings timeout. A silent or
closing peer does not fail `connect` at all: it returns, and the failure
surfaces on the first call.

The fix, if wanted, is round 814's shape: map an `Exception` from the
connection factory to UNAVAILABLE and pass an `RpcException` or an `Error`
through. Breaking, like round 814.

## Owner decision

2026-10-16: fix it as round 814 did. An `Exception` from the connection
factory becomes UNAVAILABLE; an `RpcException` or an `Error` passes
through. Measure the TLS handshake and the proxy CONNECT failures in the
same round. Breaking: the type a public method throws changes.
