---
refines: U-19
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: policy fields are enforced by each transport separately
breaks: a security hole on the transport nobody picked.
applied: [205, 394, 414, 501, 504, 517, 518, 523]
status: confirmed (round 394)
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

## The siblings need not be transports (round 501)

Shape 1 paid on a pair with no transport in it: two interceptors in one
directory, both classifying an error to decide whether to act on it.
`RpcRetryInterceptor`'s default predicate is narrow, documented and chosen;
`RpcCircuitBreakerInterceptor`'s was `failureOn == null ||`, i.e. everything
except cancellation. **Read alone, either file is a plausible design. Read side by
side, one of the two never had the decision made** — the fallback is what the `||`
does when the field is absent, not an answer anybody wrote down.

So the detector generalises past "N implementations of one interface" to **N
places that make the same KIND of decision**. Two defaults, two limits, two
retry-vs-give-up rules: if one is argued for and the other is a fallthrough, the
fallthrough is the finding.

> **And do not finish by copying the sibling.** The fix here is deliberately
> WIDER than the retry interceptor's set — a breaker asks "is this endpoint in
> trouble", a retry asks "is another attempt worth making", and INTERNAL/UNKNOWN
> answer the first and not the second. The comparison is what locates the
> unconsidered default; it is not the source of the right value. Round 501's
> record has the split.

Bench `../probes/P-139-which-errors-open-the-breaker.md`.

## When one of the pair enforces and the other only DOCUMENTS (round 504)

A third kind of pair, twenty lines apart in one file: two functions that are
documented inverses of each other. `rpcMethodPathFromKey` splits a binding key on
the LAST dot, and its doc states the invariant that makes that correct — *"a service
name may contain them, a method name may not"*. `parseRpcMethodPath` applied ONE
token pattern to both halves of the path, and the pattern admits dots. **The
invariant was enforced by a sentence**, so `('a', 'b.c')` and `('a.b', 'c')` were
distinct pairs producing one key, and a request dispatched to a method the caller
had not named.

So when comparing a pair, do not only ask *do they agree* — ask **which of them
actually CHECKS.** A precondition stated in the doc of the function that RELIES on
it is not enforced anywhere. The tell is a doc sentence of the form "X may contain
this, Y may not" with no code nearby that says so.

> **A round-trip test cannot find this, and it is worth knowing why.** Parse-then-
> format is the identity for every path legal under BOTH grammars, so the obvious
> property test guards the fix and could never have witnessed the defect. What finds
> it is two inputs that must map to different outputs — injectivity, not
> round-tripping.

**This lens has now paid on three unrelated kinds of pair** — transports (its
original parity matrix), two interceptors making the same classification decision
(round 501), and two inverse functions where one carries the rule in prose. Worth a
curate pass asking whether "compare the places that make the same decision" has
outgrown the matrix it was derived from and wants its own lens.

`../probes/P-142-which-paths-reach-one-method.md`,
`../rounds/504-the-invariant-only-the-doc-enforced.md`, B-113.

## Siblings that agree, and the negative that arrives too easily (round 517)

The lens's other outcome. Three builders assemble request metadata; B-125 claimed
they had drifted and named the case. They had not: the same header set from all
three, including the null-context row the lead pointed at.

**Read the siblings' OUTPUT, not their source, and read it where a peer would.** Two
of these three are private, so the diff had to be taken on the wire — and that is the
better place anyway, since a builder can agree while its caller sends something else.

> **A negative that arrives too easily deserves a second look.** The first rig
> reported three identical rows and they were all `x-rpc-conn-window-update`: the
> transport's own connection window-update is a metadata frame and precedes the
> request, so "the first metadata frame" was never the one under test. Three matching
> rows is the expected shape of the TRUE answer and of that bug, which is exactly why
> it passed unnoticed until the rows were read rather than counted.
>
> The control that catches it is a dimension that MUST differ: here the with-context
> arms, where `grpc-timeout` appears. If nothing in the table varies, the rig has not
> been shown capable of seeing a difference.

**And separate a lead's argument from its evidence.** B-125's structural point — three
copies, so the next header rule lands in one — survives intact. Only the claim that
drift had already happened is refuted. That moves the refactor from "fix a defect" to
"the owner's preference", which is a different decision with a different owner.

`../probes/P-154-do-the-three-header-builders-agree.md`,
`../rounds/517-the-drift-that-had-not-happened.md`, `../checked/C-59`, B-125.

## When one sibling's tolerance is the whole finding (round 518)

The four CALL SHAPES are siblings too. Against a channel splitting every frame in
two, `unary status 13` while server-stream and client-stream both answered — same
transport, channel, codec and payload in the same run, only the responder differing.
**That simultaneity is what makes "unary only" a measurement rather than a reading**,
and it is free: the battery was going to run anyway.

> **A sibling that TOLERATES something is also evidence about how to fix the one that
> does not.** The streaming shapes cope because their parser accumulates across
> messages — which is exactly what the lead's sketch proposed for unary, and exactly
> what failed.

**The round's real lesson is about partial fixes.** Making the unary responder
accumulate turned an immediate INTERNAL into a hang, because two further layers drop
the later fragment: the pipeline feeds only `preBindMessages.first`, and
`_cleanupStream` runs straight after. Three layers, of which the lead named two.

> **When a defect spans layers, a fix to one is not a smaller improvement — it can be
> a regression.** A clear error is better than a hang. Revert, and say what the
> complete fix would cost. Check `git diff` afterwards to prove `lib/` really is back.

And the cheap alternative is worth naming whenever a sibling comparison ends this
way: the behaviour being relied on may simply be an undocumented INVARIANT. Round 507
stated one on `IRpcChannel.incoming` for the same reason. Documenting it is a
different, much cheaper decision than defending against its violation — and it is the
owner's.

`../probes/P-155-does-unary-survive-a-fragmented-frame.md`,
`../rounds/518-the-fix-that-turned-an-error-into-a-hang.md`, B-126.

## A policy field bounded by a DIFFERENT field, on one transport only (round 523)

`maxMetadataBytes` is never enforced in total — `validateMetadata` checks each header
and never accumulates. `64 headers x 8192 B = 524818 B` is ACCEPTED, 8x the limit, and
the 128-header row is refused **by the header COUNT, not by size**. So the effective
ceiling is `maxHeaders x maxHeaderValueBytes`, and the field bounds nothing that
another field does not already bound worse.

Then the lens's usual half: the channel transports ARE covered, by
`RpcChannelFrame._decodeAt` bounding the encoded blob; the HTTP transports validate
through the policy and never reach that decoder. One name, one promise, one transport.

> **Check WHICH field produced a refusal, not just that one occurred.** The last row
> refusing looks like the bound working. Printing the reason is what showed it was a
> different limit, and that the one under test never fires at all.

> **And the control has to be the thing that DOES work.** One oversized header is
> refused, so the accepted rows are about totals rather than about nothing being
> validated — without it the finding would have been much larger and wrong.

This also names a second-order question worth carrying into any fix: when two layers
bound "the same" quantity, do they count the same bytes? Here the policy counts header
text and the decoder counts the encoded blob. Round 520 found the same confusion in
`maxActiveStreams`, where two sides counted different intervals under one name.

`../probes/P-159-is-metadata-bounded-in-total.md`,
`../rounds/523-the-knob-that-is-off-by-sixteen.md`, B-197, B-129.
