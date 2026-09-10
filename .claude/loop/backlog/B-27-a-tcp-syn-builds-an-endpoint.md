---
status: open
round: 274
commit: 508fba09
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/a_tcp_syn_builds_an_endpoint.dart
reason: "owner decision — both candidate fixes change behaviour for existing users: deferring endpoint construction moves onConnectionOpened/onEndpointCreated timing, and a preface deadline is a new default that drops connections which have sent nothing"
---

# B-27 — a TCP SYN builds an endpoint and runs the application's callback

`RpcHttp2Server._handleConnection` runs on TCP accept and builds, before a
single byte has arrived from the peer: a `ServerTransportConnection`, an
`RpcHttp2ResponderTransport`, an `RpcResponderEndpoint`, and then calls
`_onEndpointCreated` — which is where the application registers its contracts,
and therefore where it opens whatever a contract opens.

Measured, 200 sockets sending zero bytes (P-25):

    server / arm         endpoints  contracts built  reclaim by default
    http2  default          200          200         none
    http2  pingInterval       0          200         the keepalive
    websocket                  0            0         idleTimeout, 2 min

Nothing counts connections. `maxActiveStreams`, `maxConcurrentHandlers`,
`halfOpenStreamTimeout` and the pre-method budget are all PER CONNECTION, so
every limit this server has is downstream of the thing being attacked. The cost
per SYN is one endpoint plus whatever the application's `onEndpointCreated`
does, held for as long as the peer keeps the socket open.

**It is not a leak.** Polled to a 15s deadline after the peers disconnect:
`endpoints 0, contracts disposed 201`. The teardown is correct; the exposure is
the hold.

**The sibling is the argument.** `rpcWebSocketConnections` yields a channel only
after `WebSocketTransformer.upgrade`, so the peer must complete an HTTP request
and pass the origin check before an endpoint exists — and dart:io's `HttpServer`
bounds a silent connection at `idleTimeout`, 2 minutes by default.
`RpcHttpServer` has one endpoint for the whole process and never does this
either. http2 is the only one of the three.

**What the existing documentation says, and does not.** `_pingInterval`'s doc
comment is accurate — keepalive is the only thing that detects a HALF-OPEN
connection — and it frames the problem entirely around NAT boxes, load
balancers and mobile networks, with numbers from a frozen TCP relay. An operator
reading it files keepalive under reliability. Nothing anywhere says that without
it, any peer holds N endpoints with N SYNs and zero bytes.

## The two candidate fixes, and why neither is a round's to make

1. **Defer construction until the first inbound bytes.**
   `ServerTransportConnection.viaStreams` needs its stream at construction, so
   this means holding the socket, waiting for the first data event, and then
   constructing with a stream that replays it. It is the correct shape — no work
   before the peer speaks — and it moves when `onConnectionOpened` and
   `onEndpointCreated` fire, which applications observe.

2. **A deadline on "accepted, and has sent nothing at all".** Much smaller:
   arm a timer after accept, and on expiry `_releaseEndpoint` + `socket.destroy`,
   reusing wiring that already exists and is tested. Safe against conforming
   clients — an h2 client sends the preface within one RTT, and under TLS the
   socket is only yielded after the handshake — but it is a new default that
   would drop a TCP pre-warming load balancer, and it needs a knob.

   Do NOT reuse `halfOpenStreamTimeout` for it. A client that connects at
   startup and makes its first call later is legitimate and common, so the
   bound must be on BYTES EVER RECEIVED, not on streams opened; conflating the
   two is the RPC-19 shape this journal keeps finding.

## Owner decision

—
