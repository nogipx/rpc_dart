---
refines: U-08
paths: [packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/src/endpoint/**]
applies: a server-side entry point has rejection exits that run before the request is registered
breaks: DoS.
applied: [272, 274, 275, 276, 277, 283, 284, 287, 288, 361, 395, 397, 399, 400, 532, 591, 604]
status: confirmed (round 397)
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

**Round 399 added the second clause, because the first alone gives a false
positive.** "Cheaper for the attacker" is only half a comparison: what matters
is cheaper for the attacker AND dearer for the server. Measured on the
http2 framing refusal against a served-call control, 2000 operations each:

```
arm        ops     ms    up B/op  down B/op   amp
served    2000    873      164.3      128.0   0.78x
framing   2000    548      134.0      216.0   1.61x
```

The peer does pay less (134 against 164 B/op), which trips the Ask as written —
and the SERVER also does less (548 ms against 873), so a refusal flood is
strictly less damaging than the same volume of honest calls, which nothing
bounds either. B-58's backstop is not justified on cost.

> **Ask both sides, or a cheap refusal that is also a cheap ANSWER reads as a
> finding.** Every earlier application of this lens happened to have a server
> cost — an unbounded drain, a built endpoint, a parked handler — so the
> question was never asked in two parts.

The one axis where a refusal can be worse is amplification: it was the only path
here writing more than it read, and the ablation names the cause — trimming
`maxHeaderValueBytes` to 24 takes it from 216 bytes down to 131 at the same
site, so the diagnostic message is the amplifier. 1.61x, and TCP will not carry
a spoofed source, so it is recorded rather than fixed.
`../probes/P-85-what-a-refusal-grind-costs.md`.

**Round 400 asked the third question in the series — who pays for the ANSWER?**
A refusal is a write, so a peer that provokes one and then reads nothing is
making the server hold it. Here it turned out the server does not: 20000 refused
streams against a peer reading nothing leave a plateau of 394, twelve seconds
apart identical, because `package:http2` queues the trailers-only HEADERS frame
instead of blocking, and its own read backpressure then stops it admitting more.

> **Producing "the peer does not read" is harder than it looks.** A peer that
> never calls `listen` applies no pressure — dart:io drains into its own buffer.
> It takes a relay whose upstream subscription is PAUSED before TCP
> backpressure reaches the far end. An arm that gets this wrong measures a
> perfectly healthy server and reads as a clean result.

`../probes/P-86-a-peer-that-never-reads.md`.

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

**Round 276 found the identical defect in the websocket server**, whose
`_refuse` drains with no deadline and is `unawaited`, so any number run at once
with nothing counting them. Its comment already cited the HTTP/1.1 sibling — for
the draining half, which is the half that existed when it was written.

    arm       origin     shape    answered   first answer
    accepted  allowed    upgrade  16 of 16   101 Switching Protocols
    refused   rejected   upgrade  16 of 16   403 Forbidden
    plain     rejected   POST      0 of 16   -                       <- before
    plain     rejected   POST     16 of 16   closed                  <- after

> **Attack the exit, not the feature.** The first attempt sent upgrade-shaped
> requests and read 16 of 16 answered — clean. dart:io hands a
> CONNECTION-UPGRADE request no body at all, and `_upgradeAllowed` gates EVERY
> request, so the holding attack is a plain POST. When a rejection exit reads as
> bounded, check that your input reached it in the shape the code takes.

And note where it is reachable: only when `allowedOrigins` or `allowUpgrade` is
configured. **Turning the security control on is what opened the path.** Round
`../rounds/276-the-same-defect-in-the-sibling.md`, bench
`../probes/P-26-refused-upgrade-has-no-deadline.md`.

## Round 361 — the same stage from the CLIENT's side

Rounds 274-275 established that a connection-oriented peer has a stage BEFORE
the protocol starts, and that the stage needs a deadline. The mirror: the side
DOING the connecting sits in that same stage, and `connect()` bounded nothing.

    arm                     elapsed   outcome
    no connectTimeout       10016ms   STILL HANGING at the probe bound
    connectTimeout: 800ms   806ms     TimeoutException

The `10016ms` is the probe's own bound, not a measurement of how long dart:io
waits — the point is that nothing in the library stopped it. A firewall that
DROPs or a balancer with no backend accepts TCP and answers nothing, which is
exactly `prefaceTimeout`'s scenario seen from the other end.

> **The pre-protocol stage is also where a client AUTHENTICATES**, and that is
> the half filed as hygiene which was not. A websocket client has exactly one
> place to put a token — the upgrade request — because there is no second round
> trip. `openWebSocket` forwarded no headers, so an authenticating server could
> not be reached through this API at all. When this lens finds a stage, ask what
> each side must accomplish IN it, not only what it must be protected from.

> **A new parameter has to reach the RECONNECT factory too** (U-10). `connect()`
> builds the factory that carries the keepalive and the compression choice; a
> token that goes only on the first upgrade authenticates exactly once. The
> bench therefore drives `reconnect()` rather than stopping at the first
> handshake — and because there is ONE `openChannel` closure serving both, the
> two header canaries fail identically, which is the honest result rather than a
> flaw in them.

`../probes/P-52-connect-headers-and-timeout.md`,
`../rounds/361-the-only-place-to-authenticate.md`.

## Round 397 — enumerate the sites, then drive EACH one

The detector says "enumerate the rejection exits". Round 395 did that for the
http2 responder, drove one of them, measured it clean, and wrote the rest into
the negative's own "does not cover" list. Two rounds later the next one down was
broken.

`_answerRejectedStream` (refused in the HEADERS) releases the stream in a
`finally` after answering. `_answerFramingViolation` (refused in a DATA frame)
did not, so reclaiming the stream depended on the PEER setting END_STREAM:

```
arm                     incoming  subs  parsers  pumps  peer saw
refused (:method GET)         0      0      0        0  grpc-status 8
bad frame, half-closed        0      0      0        0  grpc-status 8
bad frame, still open       200    200    200      200  grpc-status 8
```

> **Two refusal exits in one file are two measurements, not one.** They are
> siblings — same duty, 200 lines apart — and the reading that establishes one
> says nothing about the other. Every zero above comes from a site that calls
> `releaseStreamId`; the 200s come from the one that does not.

> **The arms must be a PAIR that differs by one bit.** Half-closed against not,
> same five bytes, same answer. A single arm reads as "refusals are clean" or
> "refusals leak" depending on which one gets written, and both readings are
> defensible from one row.

The refusal is also where a running call has to be ENDED, not only where state
is released: the parse error reaches an upload handler's request stream but
nothing closes it, so the handler sat in its `await for` with the stream already
answered. `../rounds/397-the-refusal-that-kept-the-stream.md`, `../probes/P-84`.

**Round 277 aimed it at the canonical instance and came back CLEAN.** HTTP/2
Rapid Reset (CVE-2023-44487) is this shape exactly — a stream opened and reset
is beneath `maxActiveStreams` by construction — and rpc_dart dispatches nothing:
0 handlers from 200 resets, against 4 from 200 normal calls at a ceiling of 4.
The cancellation is processed before the pipeline reaches dispatch.
`../checked/C-32-rapid-reset-dispatches-nothing.md`. The CPU half of the CVE —
HPACK decode and stream churn at a rate nothing bounds — is named there and not
measured.

**Round 532 — the refusal was correct and the REPORT was the cost.** A plain GET to
the websocket port is answered 400, which is right, and dart:io's transformer then
puts a `WebSocketException` on its output stream — the server's `connections` stream
— so every one reached `onError`: an error-level record and an `onConnectionError`,
at whatever rate the requester chooses. Ten GETs, ten of each, against a control of
zero for ten real handshakes.
`../probes/P-165-what-does-a-health-check-cost.md`, B-136.

> **A refusal has a second output nobody budgets: the operator's log.** The lens's
> usual question is what a refusal COSTS the server. Ask also what it WRITES —
> anything an unauthenticated caller can make appear in an error log at its own rate
> is the same shape, and the cheapest instance of it is a load balancer doing its
> job.

> **Measure the answer alongside the noise.** Silencing a report and removing it are
> indistinguishable from the log side, and the second is worse. Every arm here reads
> the status code the peer actually received.

> **Fixing a reporting path can move a bound.** Rejecting non-upgrade requests
> ourselves means DRAINING them ourselves, so a hold that existed only on servers
> with a gate configured now exists on all of them. Bounded, and the same bound — but
> the round that widens a surface owes the note.

## Round 591 — the refusal that pays for its own cleanup

Round 399 added the Ask's second clause: cheaper for the attacker AND dearer for
the server. 591 is the first application where the SERVER side comes back negative
for a structural reason worth keeping.

B-207: the decompression limit throws from inside the sink, so `close()` is skipped
and the native zlib filter waits for a finaliser — "at a rate the peer chooses".

```
                 CONTROL   WITNESS
20000 attempts   +30 MiB    +6 MiB
20000 attempts   +31 MiB   -53 MiB
```

> **A refusal path that must do the expensive work in order to decide to refuse
> cannot be driven cheaply, and that bounds its own cost.** Tripping this limit
> requires decompressing UP TO the limit, so every refusal generates GC pressure in
> proportion to the ceiling it is about to breach — which is exactly what runs the
> finaliser the lead was worried about. Before pricing a refusal, ask what the
> SERVER had to spend to reach the decision: if that spend is itself the cleanup
> budget, the leak is self-limiting.

> **And the control is the arm that should GROW.** Here it is the successful
> decompressions, which reach `close()` properly. Naming which arm is expected to
> climb before running it is what stops a null result reading as "the instrument
> saw nothing".

`../probes/P-209-what-a-refused-bomb-leaves-behind.md`,
`../rounds/591-the-refusal-pays-for-its-own-cleanup.md`, B-207.
