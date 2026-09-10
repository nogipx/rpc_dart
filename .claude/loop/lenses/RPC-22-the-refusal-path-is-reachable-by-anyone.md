---
refines: U-08
paths: [packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/src/endpoint/**]
applies: a server-side entry point has rejection exits that run before the request is registered
breaks: DoS.
applied: [272, 274, 275]
status: confirmed (round 275)
---

# RPC-22 — The path a peer reaches without being accepted

## Shape

Every guard on the accepted path — a deadline, a counter, a cap — has to be
asked of the REFUSAL path separately. That path is reachable by anyone: no valid
content-type, no valid method, no credentials, no stream. And it is where nobody
looks, because "we already said no" reads like the end of the story rather than
the start of an unaccounted piece of work.

The catalog shape it refines names the opposite direction — U-08 is one limit
applied to BOTH the body and the diagnosis of why there is no body. This is the
same question the other way: a limit applied to the body and to nothing else.

## Detector

Enumerate the rejection EXITS of each server-side entry point, and for each ask
which of the accept path's guards it inherits. In `rpc_dart_http` that is
`_reject`'s five callers — transport closed (503), not POST (405), at the stream
ceiling (503), wrong content-type (415), bad method path or metadata (400) —
every one of them reached before `_pending[streamId]` exists, so before any
counter and before any deadline.

Then the second half: does the rejection still do WORK? Draining a body,
building a page, logging, hashing. Work on a path with no admission control is
work an unauthenticated peer commands directly.

## Ask

Which is cheaper for an attacker — being accepted, or being refused? If the
answer is "refused", the refusal path is the attack surface.

## Evidence

**Round 272, `RpcHttpResponderTransport._reject`.** It drains the request body
before answering — correctly, because dart:io tears down a connection whose body
was left unread — and that drain had no deadline. `bodyReadTimeout` was applied
around `readBody()` and nowhere else, while the method's own doc comment said
wall-clock was bounded by it. Sixteen sockets promising a 100000-byte body and
sending five bytes, same server, `bodyReadTimeout: 500ms`, one header different:

    content-type: application/grpc  ->  16 of 16 answered 408 within 3s
    content-type: text/plain        ->   0 of 16 answered, all 16 draining

`pendingRequests` read 0 in both arms. So the server's own health check reported
idle while sixteen handler invocations sat in a read loop with no end, and the
attacker's cost was one socket and ~90 bytes each — cheaper than the accepted
path, which is bounded twice over.

> **A timeout that is written on the happy path is not a policy, it is a local
> variable.** The knob was documented as the slowloris answer for this
> transport; it covered the branch its author was looking at. Grep the knob, not
> the intent: `bodyReadTimeout` appeared at exactly one call site.

The fix cancels the subscription rather than merely timing out the future — a
`.timeout()` on the drain returns the status while the read loop keeps running,
which bounds the handler and nothing else. Delivering the status on expiry was
already best-effort and is now given up: an over-budget refusal costs the peer
its connection.

Bench `../probes/P-23-the-refusal-path-has-no-deadline.md`; round
`../rounds/272-refused-is-cheaper-than-accepted.md`.

**Round 274 found the stage EARLIER than any rejection.** On a connection-
oriented server there is a peer that has been accepted and has not yet said
anything, and `RpcHttp2Server._handleConnection` is wired to the accept stream:
it builds the transport, the endpoint, and calls `onEndpointCreated` — where the
application registers its contracts — before a single byte arrives. 200 sockets
sending zero bytes:

    server / arm         endpoints  contracts built  reclaim by default
    http2  default          200          200         none
    http2  pingInterval       0          200         the keepalive
    websocket                  0            0         idleTimeout, 2 min

> **Every limit that is PER CONNECTION is downstream of the peer who has not
> opened a connection's worth of anything yet.** `maxActiveStreams`,
> `maxConcurrentHandlers`, `halfOpenStreamTimeout` and the pre-method budget are
> all per connection here, so a peer that never opens a stream is beneath all
> four, and nothing counts connections. Ask where the FIRST counter sits, then
> ask what an attacker can do before reaching it.

Deferred as B-27; the owner chose the deadline and round 275 shipped it
(`prefaceTimeout`, 30s, armed on accept and disarmed by the connection preface).

> **Price a pre-protocol bound in BYTES the attacker must send, before shipping
> it.** The fix was first proposed as "disarm on the first inbound byte", which
> raises the attacker's cost from 0 to 1. Binding it to the 24-octet preface
> raises it to 24. Measured, that is the whole difference:
>
>     arm      bytes sent  endpoints after 2s
>     default      0                0
>     preface     24              200
>
> So a deadline of this kind bounds traffic that never speaks the protocol —
> scanners, TLS probes, a load balancer that pre-warms TCP — and buys nothing
> against a peer that is willing to conform. The second stage needs a different
> mechanism, and here it already existed: the keepalive. Say which stage a bound
> covers, or it will be read as covering both.

Bench `../probes/P-25-a-tcp-syn-builds-an-endpoint.md`; rounds
`../rounds/274-work-before-the-peer-speaks.md` and
`../rounds/275-a-deadline-on-saying-nothing.md`.
