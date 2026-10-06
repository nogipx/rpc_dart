---
status: open
round: 667
commit: ae33d09d
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
probe: none — the round-667 sweep found it by reading; nothing run
reason: "bench — on HTTP/1.1 every call is its own request, so which failures mean the CONNECTION is a question the transport has to answer per exception type, and no witness has been built"
---

# B-246 — an HTTP/1.1 request failure retires the client connection

Found by round 667's sweep of the class it fixed: an error about one stream put on
`incomingMessages` without the advisory marker.

## The shape

`RpcHttpCallerTransport._emitError` puts every per-request failure on the
broadcast as-is. `RpcClientConnection` retires the transport on any broadcast
error that is not `IRpcAdvisoryChannelError` or `RpcFrameException`, and
retiring closes it -- failing every other call in flight.

## Why it matters

Unmeasured. Some of these failures do mean the server is gone (connection
refused); others are about one request (a reset mid-body, a timeout). Before
round 667 the http2 equivalent, one RST, failed three innocent calls with
UNAVAILABLE.

## Witness a round would build

`RpcClientConnection` over the http1 caller, three slow calls in flight, one
request that fails alone (the server closes that socket); count the innocent
calls' outcomes and the transports built.

## Fix sketch

Mark failures that cannot mean the server is unreachable as advisory, the way
`_emitStreamError(connectionWide:)` does on http2.

## Owner decision

—
