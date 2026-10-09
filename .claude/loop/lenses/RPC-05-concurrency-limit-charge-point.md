---
refines: U-07
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: something is HELD and must be given back — an RpcSecurityPolicy field, a buffer bound, a one-probe gate, or a request the caller of a lifecycle method is awaiting
breaks: "one way a dead limit, the other way a DoS: an unbounded rise in handlers, or denial of service."
applied: [214, 215, 245, 266, 271, 351, 372, 382, 463, 467, 491, 494, 502, 508, 520, 733]
status: confirmed (round 494)
rank: 20
---

# RPC-05 — Where a concurrency limit is charged

## Shape

A new limit charges the resource at the wrong point of the lifecycle.

## Detector

For every `RpcSecurityPolicy` field, where exactly it is checked: stream
admission, handler entry, dispatch. Then the limits that are NOT policy fields —
rounds 245 and 351 both found the defect in one: anything that holds a counter, a
byte total or a single slot and hands it back later. Grep for the give-back
(`= false`, `--`, `remove`) and ask which endings reach it.

## Ask

Charging at entry — is it a no-op against a burst? Charging at admission — does
it deny service to half-open streams? And: **enumerate the endings**, then check
each one reaches the release.

## Evidence

30 calls past a ceiling of 3 when charged at entry; 8 metadata-only frames
refused every call for 60 s when charged at admission. Only dispatch works.

**The origin, imported from private memory after round 235.**
`maxActiveStreams` does not bound how many handlers RUN; it bounds live stream
STATE, and the two coincide only while handlers cooperate. Dart cannot preempt a
running `async` function, so a deadline cancels the token and then falls back to
`_cleanupStream` after a 2 s grace — which frees the stream state AND the
admission slot. For an uncooperative handler the first is right and the second is
not: the work continues with its slot back in the pool. Against
`maxActiveStreams: 4`, one call every 250 ms with a 40 ms deadline, **37
concurrent handlers after 20 s and still growing linearly**, while
`activeResponders` read 3-4 the whole time. Closed in round 114 by
`maxConcurrentHandlers` (default null, opt-in, charged at dispatch): 37 -> 4 on
the same attack.

## Round 245 — the limit that exempts a dimension

`security_policy.dart` had not changed since the 215 sweep, so the field half of
the detector had nothing to look at. The defect was in a limit that is not a
policy field: `BufferedBroadcastController`'s byte bound weighs
`RpcTransportMessage.bufferedBytes`, which counted the payload only.

    arm        admitted  retained    bound that stopped it
    payload      256      16.0 MiB   the byte bound
    metadata    4096     256.0 MiB   the EVENT count     <- before
    metadata     255      15.9 MiB   the byte bound      <- after

> **Ask WHAT a limit charges, not only WHERE.** The exemption was justified in a
> comment — metadata "is small and bounded by the policy's header limits" —
> which is true per frame and false in aggregate at `maxMetadataBytes` x 4096.
> A bound with a dimension the peer controls and the weigher ignores is not a
> bound. Bench `../probes/P-21-metadata-escapes-the-byte-bound.md`.

> **Saturating the connection HIDES it, and that is a trap for any admission
> limit here.** With the table permanently full, later calls are rejected before
> dispatch: 43,908 calls in 14 s produced exactly 8 handlers against
> `maxActiveStreams: 8`, so a load test reports the ceiling holding. PACING past
> the reclaim grace is what defeats it.

**Both neighbours of the right charge point are measurably wrong, in opposite
directions**, which is why this lens exists: handler ENTRY reads as the more
precise semantic and is a no-op against a burst (found only over a REAL
transport — the paced core test stayed green); stream ADMISSION is a denial of
service, because a stream is half-open from its opening frame until dispatch, so
8 metadata-only frames refuse every call for the whole `halfOpenStreamTimeout`.
That second one was found by attacking the round's own fix one round later.

**The matching WHERE question is the release wrapper's placement** (round 116).
It sat on the innermost user handler, inside middleware and interceptors, so work
OUTSIDE the handler was released with the stream: an interceptor parked on an
auth lookup gave **2 interceptors live against a ceiling of 1**, accumulating
exactly like the handler case. It now wraps the whole `handleUnary` /
`handleClientStream` / `handleServerStream` / `handleBidirectionalStream` call at
all 8 dispatch sites.

> **Three separable halves, so three canaries, and each isolates cleanly:**
> ceiling never refuses -> 3 witnesses fail; released with the stream -> only the
> abandoned-call witness fails; never released -> the ATTACK witness stays green
> while ordinary traffic fails ("call 2 was refused; a slot is leaking"). A
> one-sided canary would have shipped that ratchet.

> **When a new assertion fails, check the FIXTURE before the code.** The first
> version of the interceptor test parked the interceptor and used a handler that
> also parks, so the chain could not unwind and "the slot comes back" failed for
> an unrelated reason.

## Round 271 — the transport releases its charge, the pipeline never hears

The first application outside core, and the detector needed one more question:
**who else was charged when you were?** `RpcHttpResponderTransport` opened the
pipeline's stream (the metadata frame) before reading the request body, then
cleaned up only its OWN `_pending` when that read never completed. Two budgets,
one release. Eight aborted requests against `maxActiveStreams: 8`:

    arm      bodyReadTimeout  pendingRequests  openStreams  ordinary call
    timeout  500ms            0                8            status 8   <- before
    timeout  500ms            0                0            OK         <- after

> **A limit is not released by the layer that charged it — it is released by
> whoever can still see the stream.** `bodyReadTimeout` is what the docs point
> at for this attack and it discharged the transport's budget exactly as
> documented, which is what made the pipeline's look fine. When two layers open
> state for one request, ask each teardown path which of them it reaches.

And the mitigation that DID hold — `halfOpenStreamTimeout` — bounds time while
the attacker controls rate: 60 s x ~68 aborted requests a second keeps a
default 4096-slot table full forever, at ~33 KiB each. Worse here than anywhere
else because `RpcHttpServer` keeps ONE responder endpoint for the whole server,
so C-29's "responder endpoints are PER CONNECTION" has an exception.
Bench `../probes/P-22-body-that-never-arrives.md`.

## Which fields this detector actually covers

Round 214 enumerated all sixteen. **Most cannot suffer this shape at all**:
`maxMessageLengthBytes`, `maxHeaders`, `maxMetadataBytes`, `maxHeaderNameBytes`,
`maxHeaderValueBytes`, `maxMethodPathLength`, `maxMessagesPerChunk` and
`closeOnProtocolError` are pure predicates — checked at a point, holding
nothing, so there is no release to get wrong. Narrowing the detector to the
fields that HOLD state is most of the work.

    maxConcurrentHandlers  round 214, clean, ablation-validated (P-06)
    the four fc fields     rounds 206-213, exhaustively; 212 fixed a leak
    maxActiveStreams       round 212, every counter pinned back to zero
    halfOpenStreamTimeout  round 205, 20 parked streams reclaimed to 0
    the pre-method budget  round 215, clean, two controls (P-07); its ceiling
                           is maxMessageLengthBytes

**`maxBufferedBytes` is NOT one of these** — round 214 said it was, and that was
wrong. It is the gRPC parser's reassembly ceiling in `parser.dart`,
`if (_state.available > _maxBufferedBytes) throw`: a threshold read off the
buffer's own occupancy, with no separate counter that can desync from it. It
belongs with the pure predicates. Corrected in round 215.

Round 214's result, six calls churned against a ceiling of three, then a burst
of twelve:

    normal 3, throw 3, cancel 3, deadline 3    releases in place
    normal 0, throw 0, cancel 0, deadline 0    _releaseHandlerSlot ablated

> **Charging is only half a lifecycle.** The original evidence was about WHERE a
> limit is charged; the other question, and the one round 214 asked, is whether
> every way a call can end gets back to the release. Enumerate the endings, not
> the happy path.

Round 215 adds the reading half of that. The pre-method budget's `endStream`
ending holds its bytes and looks exactly like a leak, and is not one — it is the
reorder deferral, bounded by `halfOpenStreamTimeout`. Two controls were needed to
say so: the same run with a short timeout, and an ablation of the release.

> **A held resource is not a leaked one.** Before calling a non-zero counter a
> leak, find the bound that is supposed to release it and shorten THAT. If the
> number goes to zero, you have found a policy, not a defect. Recorded as C-20.

## Round 351 — a one-slot limit, and the ending nobody wired

The smallest limit in the library: the circuit breaker's half-open gate, one
slot, `bool _probeInFlight`. `_checkState()` charges it; `_wrapStream` gives it
back from the source's `onError`, the source's `onDone` and an abandon timer.
The consumer's cancel reaches none of the three — `onListen` cancels the timer,
and a cancelled subscription never delivers `onDone` — so `stream.first` or
`take(n)` on a probe pinned the gate and the breaker refused every later call
forever, recoverable only by `reset()`.

    arm                   state after probe   admitted/attempted
    keep-serverStream     closed              5/5     control
    cancel-serverStream   halfOpen            0/5  -> 5/5
    keep-bidi             closed              5/5     control
    cancel-bidi           halfOpen            0/5  -> 5/5

> **Round 214's rule, restated on a gate instead of a counter: enumerate the
> endings.** Four of the five had a release and the fifth had none, and the
> missing one was the ordinary consumer idiom. The give-away was a COMMENT — *"the
> probe gate is released by source termination or the abandon timer, not here"* —
> asserting a release from two mechanisms that, by the time `onCancel` runs,
> cannot fire. U-01 and rule one: the code, not the prose.

> **The sibling had it right.** `rpc_dart_opentelemetry`'s `_wrapWithSpan` is the
> only other interceptor in the workspace that wraps a stream around per-call
> state, and it ends its span in `onCancel`. One `grep -n onCancel` across the
> interceptors is the whole sweep (U-14).

## Round 463 — a limit that is charged NOWHERE, and the ending that was already covered

Every application above is about a limit charged at the wrong point. This one is
not charged at all: `RpcHttpCallerTransport` referenced `maxActiveStreams`
nowhere, so a client configured with 4 opened 12 concurrent calls.

```
                    admitted  refused  peak handlers  peak server requests
core (channel)         4         8           4
http2                  4         8           4
HTTP/1.1              12         0          12                12
```

> **Before accepting "this limit is meaningless here", measure what is supposed
> to be standing in for it.** The lead's counter-hypothesis was that the
> `HttpClient` connection pool already bounds concurrency, which would make the
> ceiling redundant rather than missing. Twelve simultaneous requests at the
> SERVER says otherwise, and `dart:io`'s `maxConnectionsPerHost` defaults to
> unlimited. A plausible substitute mechanism is a claim, and it takes one
> counter on the far side of the wire to settle.

> **The parked handler is not a detail of the bench, it is the bench.** With a
> handler that returns, twelve calls retire faster than they are issued and never
> hold four slots at once — so every transport reads the same and the ceiling is
> never reached. Round 245 records the mirror trap: SATURATING the connection
> hides a leak. A concurrency limit needs the arrivals held open against it, at
> exactly the rate that keeps the counter at its ceiling.

The endings half came back the other way for the first time. Four of them —
completion, connection refused, HTTP 503, a 200 that is not gRPC — were run with
the transport's second release site ABLATED, and all four still returned the
slot: the endpoint calls `releaseStreamId` on every one.

> **An ending that is already covered is worth measuring too.** The rule has
> always been "enumerate the endings and check each reaches the release"; the
> result here was that a release site is REDUNDANT, which is a different thing
> from unnecessary. It was kept, because the coverage belongs to another layer
> and the failure if that changes is the worst one this shape has — not a leak
> but a RATCHET, a ceiling that shuts for good N calls into a process. What the
> measurement buys is that the line is documented as redundant-today rather than
> being indistinguishable from an oversight.

`../rounds/463-the-ceiling-the-pool-did-not-cover.md`,
`../probes/P-112-what-a-caller-ceiling-is-for.md`.

## Round 467 — the REFUSAL is part of the lifecycle too, and it answered twice

Every application above is about charging or releasing. 467 is about the third
thing a limit does: refuse. A call opened as a peer opens one — metadata, then
payload — is TWO frames, and both refusals in `responder_pipeline` answered both:

```
draining, a NEW call    [status=14, status=14]
ceiling 1, a 2nd call   [status=8,  status=8]
```

> **A refusal has a lifecycle: decide, answer, and record that the id is done.**
> The third step existed — `_cleanupStream` remembers the id — and ran a
> microtask too late, because every call site fires the helper through
> `_detached`. So the defect is not a missing give-back but a LATE one, which the
> detector for a leak would never surface: nothing accumulates, the counters all
> return to zero, and the damage is on the wire.

> **`async` bodies run synchronously to the first `await`, and that is a place to
> put a fact.** Moving the remember above the first await put it back on the call
> site's own stack. Sixteen call sites, one line, because the race was in none of
> them.

Method note, which cost this round its first ceiling arm:

> **A bench for a SERVER limit must not give the ceiling to the client too.**
> `RpcChannelTransport.pair(policy:)` configures both ends, and since round 463
> the caller's own `createStream` refuses first — so the arm measures the client
> and reports it as the server. C-29's test note said this before round 463 made
> it true on every transport.

`../rounds/467-a-refusal-that-answered-twice.md`, `../probes/P-106-what-a-late-frame-on-a-closed-stream-is-told.md`.

Bench `../probes/P-43-cancelled-stream-probe.md`, whose control took two attempts
to aim: the first varied the cancel AND whether the source terminated, which
cannot distinguish "cancel skips the release" from "a live source has not
released yet". `../rounds/351-the-ending-nobody-wired.md`; the neighbouring
ending that releases but answers wrongly is `../backlog/B-36-the-abandon-timer-fabricates-a-success.md`.

## Round 491 — the thing held can be somebody else's REQUEST

Every application above releases a counter, a budget or a gate. On HTTP/1.1 the
thing `releaseStreamId` holds is a `Completer<Response>` that the shelf server is
AWAITING — so the release is not an accounting entry, it is the only ending the
HTTP exchange has.

    handler ignores its token     requests arrived 1, answered 0
    handler cooperates (control)  requests arrived 1, answered 1

> **Ask what the method's caller is waiting for.** `releaseStreamId` returns a
> bool and reads as bookkeeping; the object it drops is the one holding a socket
> open. The detector extends from "what is charged and when is it released" to
> "who is BLOCKED on this being released, and does the release reach them".

> **The path in is the one designed for the worst case.** The pipeline's deadline
> reclaim exists precisely for a handler that ignores its token, and it
> deliberately sends no trailer — a decision about the STATUS, correct on its own
> terms, which left the exchange with no ending at all. When a comment explains
> why something is NOT sent, ask what else was riding on it.

And the second finding is the reason this was invisible: `health()` counts
`_pending`, which the reclaim had already emptied, so it read
`pendingRequests: 0` while the response was unwritten. **A counter that a
teardown decrements cannot report work the teardown abandoned.**

`../probes/P-130-does-a-reclaimed-stream-answer-its-request.md`,
`../rounds/491-the-call-ended-and-the-request-did-not.md`, B-100.

## Round 494 — ask the ACQUIRE side, not just the release

Round 491 asked what a release fails to give back. Round 494 is the mirror: the
release is correct and the ACQUIRE is too broad, so the set fills with things the
release was never meant to cover.

`_peerStreamIds` records an inbound id when `!_idsOnThisConnection.contains(id)`
— "not ours right now", where the invariant wanted "theirs". Two ordinary things
satisfy the first and not the second:

    heartbeat 100ms for 3s    peer ids 0 -> 29     no heartbeat (control) 0 -> 0
    50 cancelled calls        peer ids 0 -> 50     50 completed  (control) 0 -> 0

> **A set with an invariant is measured against the invariant, not against a
> size.** "Streams the peer minted and this side is still answering" means EMPTY
> on an idle connection, so the bench needs no threshold and no notion of "too
> many" — it reads zero or it does not. Every leak lead phrased as "grows without
> bound" has a sharper form hiding in the field's own doc comment.

> **And the release cannot fix an acquire that is wrong.** The sketch's first
> option — remove the entry in `releaseStreamId` — cannot work here, because the
> trailer arrives AFTER the release and is re-added. When both an acquire and a
> release are candidates, check the ORDER of the events that reach them.

The fix is one clause, `m.methodPath != null`: a methodPath is what minting looks
like, it is how a peer opens a call, and it is what the responder pipeline itself
keys on.

> **When a fix makes every witness read ZERO, the guard is doing most of the
> work.** A transport that had stopped recording anything passes all four arms
> here. The guard drives a real reverse call and blocks inside the handler, so
> the count is read while the peer's stream is open: `1`, then `0`.

`../probes/P-132-does-the-peer-id-set-return-to-zero.md`,
`../rounds/494-minting-is-what-a-methodpath-means.md`, B-103.

## The charge whose COUNT can be zero (round 502)

`RpcRateLimiter` charged client-stream and bidi calls inside `handleData`, one
token per inbound request message. The charge point exists, it is correct, and the
number of times it runs is the number of messages the client sent — which can be
none. A bidi subscription sends none by definition, so those calls were never
charged at all: 100 of 100 admitted against a limit of 5, with no upper bound.

**So a charge point driven by a repeating event has a zero case, and the zero case
is a bypass.** The detector is not "is it charged" but *what is the minimum number
of times this can run for one call* — and if that minimum is zero, the call is
free. Unary and server-stream in the same class charge at establishment, so they
have no such case; the gap was exactly the two shapes whose driving event is
optional.

> **Fixing it is where the control earns its place.** The obvious fix — charge at
> establishment as well — closes the bypass and changes the cost of every call that
> DOES send messages, halving the effective limit for one-message calls. The arm
> that reads this is the same shape as the witness with one message added, and
> without it the additive fix looks like a clean pass. The shipped form prepays the
> first message against the establishment token, so cost is `max(1, messages)` and
> only the broken case moves.

`../probes/P-140-what-the-rate-limiter-admits.md`,
`../rounds/502-the-shape-that-was-never-admitted.md`, B-111.

## When the RELEASE is a listener somebody has to remember (round 508)

A buffered broadcast charges memory on `add` and releases it when a listener takes
the event. `RpcChannelTransport` added EVERY inbound message to it, including
responses already routed to their own stream controller — so on a caller-only
endpoint nothing released, and `startCallerListening` exists to attach a listener
that does nothing except drain. Its doc says so outright: *"this subscription exists
to keep the buffer drained."*

**That comment is the detector.** When the release point is a subscription rather
than a call, the charge is paid by whoever forgets — and forgetting is invisible
until the buffer is full. Grep for listeners whose body is empty, and for doc
comments explaining why a subscription that consumes nothing must exist. Each one is
a charge that should not have happened.

The fix is not to make the release more reliable but to stop charging: skip the
broadcast for messages already routed. Measured with the observer detached, after a
server stream was fully consumed — `1001` replayed to a late subscriber for 1000
delivered, then `0`.

> **Check which SIDE of the stream is charged before writing the skip.** Ownership
> here is id parity: a client issues odd ids, a server even, so "locally initiated"
> is `isClient ? id.isOdd : id.isEven`. Invert it and every server silently stops
> discovering calls — the guard that catches that reads the responder's broadcast off
> the transport and asserts the ids it sees are odd, which a guard checking only that
> a call succeeded would not.

> **And separate the two things riding on one stream before believing the fix is
> safe.** Errors reach the same controller through `addError`, which the skip does
> not touch — so the subscription is still needed, for a different reason than
> before. A round that had skipped the whole dispatch would have made a caller deaf
> to channel failures.

`../probes/P-146-what-the-second-dispatch-costs.md`,
`../rounds/508-work-added-to-undo-work.md`, B-117.

## One field, two sides, two different intervals (round 520)

The release point again, and this time the charge is right and the RELEASE is early:
a unary call's request is complete the moment it is sent, so `finishSending` gives the
slot back while the call is still outstanding. `maxActiveStreams` on a client bounds
request-SENDING; on a server it bounds outstanding calls. One field name, two
intervals.

**So when a limit exists on both sides of a connection, measure it on each side
SEPARATELY — and beware the harness that configures both at once.**
`RpcChannelTransport.pair(policy:)` applies one policy to both, and from the caller a
server refusing at its own ceiling is indistinguishable from a client doing so. The
first run here produced `4 refused` and the lead looked refuted; rebuilding with a
byte pipe per side and a policy each gave `0 refused`.

> **Keep the ambiguous run as the control.** The both-sides measurement proves the
> mechanism works and the rig can provoke a refusal, which is exactly what makes the
> later zero mean "the client declines to count" rather than "the probe never filled
> anything". The wrong first attempt became the thing that validated the second.

> **And check which direction a fix's failure runs before attempting it.** Releasing
> the slot too early admits too much; releasing it never refuses every subsequent call
> for the life of the connection. When the asymmetry is that bad, a fix wants the
> release point established per call shape first — `releaseStreamId` and the terminal
> inbound frame are not the same event, since a locally cancelled call never receives
> one.

`../probes/P-157-what-the-client-ceiling-counts.md`,
`../rounds/520-two-sides-counting-different-things.md`, B-128.
