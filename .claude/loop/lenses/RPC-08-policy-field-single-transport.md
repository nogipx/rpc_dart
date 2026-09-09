---
refines: U-19
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: policy fields are enforced by each transport separately
breaks: a security hole on the transport nobody picked.
applied: [205]
status: confirmed (round 119, off-journal)
---

# RPC-08 — A policy field checked on one transport

## Shape

A new `RpcSecurityPolicy` field is enforced where it was written and inert at
its neighbours.

## Detector

The matrix «policy field x transport package»; for each cell, a behavioural
probe, not a grep for a mention. Widen it past policy fields to CAPABILITIES —
this repo has three servers, three caller transports and three responder
transports filling the same roles, so one battery run against all of them gives
a built-in control and there is no arguing about what "correct" means.

Two shapes, and both pay:

1. *One sibling has X, the other does not* → the gap is a defect.
2. *NEITHER has X, but the protocol or ecosystem expects it* → a missing
   feature. Graceful shutdown came from asking what gRPC servers have that these
   did not: neither drained on `stop()`, so a rolling deploy dropped every
   in-flight call.

> **OWNER'S QUALIFIER (round 101): match BEHAVIOUR, not code, and across every
> transport EXCEPT `rpc_dart_http`.** Transport-specific implementations are
> expected; do NOT force a shared abstraction because two siblings look
> asymmetric in source. http2 in particular follows its own specification and
> rpc_dart does not control both ends of it, so its code will diverge. What must
> match is the behaviour of the finished system, and what must never differ is
> leaks or security holes. `rpc_dart_http` is unary-only, so the streaming shapes
> do not exist there at all — the four streaming-capable transports (http2,
> websocket, isolate, wasm) are the set that must behave identically. **Treat a
> code-shape difference as a lead, not as a defect in itself.**

## Ask

Is the field MENTIONED or ENFORCED? Does the refusal name that very field? And
for a capability: when one sibling is EXEMPTED from a shared safeguard because
it "has its own", does the substitute actually run? *The exemption is a comment,
not evidence* — http2 set the rpc-level window to null on the grounds that
HTTP/2 has native flow control, so every generic test of the rpc-level window
passed while the native one was bypassed at two hops.

## Evidence

Checking that "the field is mentioned somewhere" gave full coverage, while a
behavioural probe found a whole transport where it was inert. Round 205 then
measured the channel transports: peaks of 30/3/1 against the ceilings with a
no-ceiling control, and 20 half-open streams reclaimed to 0 in 3 s.

**The capability axis, imported after round 234 — it is the productive one once
defect-hunting goes barren**, three rounds running (80, 81, 82) after three
barren sweeps:

    slow-reader battery, round 92    websocket +1023 items (4.0 MiB, flat)
      handler produces flat out,     http2     +33906  (132.4 MiB, CLIMBING)
      client pauses after 5          -> http2 had no working response-direction
                                        backpressure at all (2a0476ef)

    keepalive, round 80              websocket got server-side keepalive in
                                     round 63; nobody asked whether its sibling
                                     had the hole. It did: endpoints 5,
                                     contracts disposed 0, unchanged at t+30s,
                                     against 0/5 by t+5s with pingInterval

    truncated stream, http2          websocket: unary UNAVAILABLE, stream
      kill the server mid-call       errors=[RpcStatusException] done=true
                                     http2:    unary UNAVAILABLE, stream
                                     errors=[] done=true  <- silent data loss

    peer death, round 39             websocket FATAL (a call reached the closed
                                     inner transport, status 14 into the root
                                     zone, isolate killed); http2 LIED
                                     (health() said "transport ready" with the
                                     server gone) -- and the report is what a
                                     supervisor polls

    isolate, round 51                VM half clean on both shapes; the WEB half
                                     was the defect (ef43ee29) -- no
                                     worker.onerror wiring at all, so a 404'd
                                     worker returned a HEALTHY transport after
                                     10 s with every call hanging

> **Why unary hid the truncation:** core's unary caller already treats "stream
> closed without a response" as an error, so only a call that has ALREADY
> produced output can be truncated silently. **Any sibling battery must include a
> streaming shape.**

> **When a transport has a VM and a WEB implementation of the same API, diff
> those two as siblings as well** — the web one is where the platform's death
> signal is easy to forget. And an accepted-but-unused parameter is worth
> grepping for on sight: `startupTimeout` was accepted and never used, both waits
> hard-coded to 5 s and both swallowing the timeout with `onTimeout: () {}`.

**Batteries worth running:** an in-flight call when the peer dies; a call after
close; an unregistered method; an oversized message; `close()` twice; `isClosed`
versus `health()` agreement.

**Probe traps this axis paid for.** `HttpServer.close(force: true)` does NOT kill
already-upgraded WebSockets — they are detached from the server, so a first run
showed calls still succeeding after the "outage" because the peer had never died;
close the server-side responder transports instead. And
`HttpServer.close(force: false)` is NOT a drain: it stops listening and returns
as soon as the port is released (4 ms with a 2 s request running), so relying on
it left the caller HUNG for 20 s — worse than the forceful close it replaced.
**Measure the observable the user experiences, not the API you changed.**

**A policy field the transport hands to a DEPENDENCY needs the dependency's
DEFAULT checked** (06328514, round 139), which is a third way for a field to be
inert. `ServerTransportConnection.viaStreams` was called with no
`ServerSettings`, so every http2 connection advertised package:http2's default
MAX_CONCURRENT_STREAMS of 1000 whatever the policy said — `maxActiveStreams`
meant 4096 on websocket and isolate and 1000 on http2:

    policy 7    -> advertised 1000: a conforming client paces by the
                   announcement, opens streams it is refused, and retries
                   (status 8 is retryable) into the same wall. grpc-go and
                   grpc-java QUEUE above the limit and would have succeeded
    policy 4096 -> 1100 concurrent calls gave 1000 dispatched, 100 refused,
                   because package:http2 enforces its own advertisement

> **Not passing a setting is not neutral; it means the dependency's opinion
> silently overrides the library's.** Note the fix RAISED the effective ceiling
> 1000 -> 4096, i.e. worst case per connection ~33 MB -> ~136 MB at the ~33
> KiB/stream figure in `../checked/C-29-the-real-scope-of-the-stream-limits.md`.
> Nothing was loosened, but anyone relying on the accidental 1000 must now set
> the field explicitly.

To read what a server actually advertises: raw socket, send the preface plus an
empty SETTINGS frame, decode the server's SETTINGS at the byte level —
package:http2 exposes no accessor. Kept as `advertised_stream_limit_test.dart`
and `.dart_tool/probe/advertised_settings.dart`.

The clean results from this battery are
`../checked/C-28-sibling-batteries-that-came-back-clean.md`.
