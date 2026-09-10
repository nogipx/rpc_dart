---
round: 274
verdict: DEFERRED
packages: [rpc_dart_http2]
lens: RPC-22
bench: P-25 — new
commit: yes
---

# Round 274 — work before the peer speaks

## Target

RPC-22, one round old, taken to its own second clause: *does the rejection still
do WORK?* Rounds 271-273 asked it of `rpc_dart_http`'s rejection exits. The
harder version is the connection-oriented servers, where there is a stage
EARLIER than any rejection — a socket that has been accepted and has not yet
said anything. Nothing in the journal had asked what that costs.

## Hypothesis

`RpcHttp2Server._handleConnection` is wired to the accept stream, so everything
it builds is built before the peer has sent a byte — including
`_onEndpointCreated`, which is where the application registers its contracts.
If so, every limit this server has is downstream of the thing being attacked,
because they are all per connection.

## Before

200 sockets, zero bytes each — not even the 24-byte h2 preface.

```
server / arm         endpoints  contracts built  contracts disposed
http2  default          200          200                 1
http2  ping               0          200                 -
websocket                  0            0                 -
```

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/a_tcp_syn_builds_an_endpoint.dart`
Sibling: `packages/transport/rpc_dart_websocket/.dart_tool/probe/a_tcp_syn_against_the_sibling.dart`

Confirmed. One TCP SYN buys one `RpcResponderEndpoint` and one run of the
application's callback, held for as long as the attacker holds the socket, and
by default nothing reclaims it. RSS was measured and is unusable — -28.7, -17.5
and +0.4 MiB across three runs of the same 200 connections — so the verdict
rests on the library's own counters.

**It is not a leak.** Polled to a 15s deadline after the peers disconnect:
`endpoints 0, contracts disposed 201`. A first attempt slept a flat 2s, read
`endpoints 200`, and would have reported one.

## Mechanism

`maxActiveStreams`, `maxConcurrentHandlers`, `halfOpenStreamTimeout` and the
pre-method budget are all PER CONNECTION. A peer that never opens a stream is
beneath every one of them, and nothing counts connections. The keepalive
reclaims such a connection when configured — the `ping` arm shows it — but it is
opt-in, and even then the contracts were still constructed 200 times.

The sibling is what makes this a defect rather than a property of servers:
`rpcWebSocketConnections` yields a channel only after
`WebSocketTransformer.upgrade`, so the peer must complete an HTTP request and
pass the origin check first, and dart:io bounds a silent connection at
`idleTimeout`, 2 minutes by default. `RpcHttpServer` keeps one endpoint for the
whole process and never does this either. http2 is the only one of the three.

## After

n/a — deliberately not fixed.

## Canary

n/a. The `ping` arm and the websocket sibling are what give the numbers meaning:
one changes a single constructor argument and takes 200 to 0, the other runs the
identical attack against a server that answers 0.

## Gate

n/a — no code changed. `loop.py lint` green.

## Not fixed

**B-27**, with the reason: an owner decision, because both candidate fixes
change behaviour for existing users. Deferring construction until the first
inbound bytes is the correct shape and moves when `onConnectionOpened` and
`onEndpointCreated` fire; a deadline on "accepted and has sent nothing" is far
smaller and reuses `_releaseEndpoint`, but it is a new default that would drop a
TCP pre-warming load balancer and it needs a knob. The lead writes both up,
including the one trap: the bound must be on BYTES EVER RECEIVED and not on
streams, because a client that connects at startup and calls later is
legitimate — reusing `halfOpenStreamTimeout` would be the RPC-19 shape again.

Also recorded there and not fixed: `_pingInterval`'s doc comment is accurate and
frames the whole problem around NAT boxes and mobile networks, so an operator
files keepalive under reliability. Nothing says it is also the only thing
standing between the server and this.

## Links

RPC-22 (`applied:` gains 274, and its Evidence gains the pre-protocol stage).
Bench P-25, new. Lead B-27, new. C-29 is the record that says these limits are
per connection; this round is the case where that is the problem rather than the
mitigation.
