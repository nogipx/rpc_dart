---
refines: U-07
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: something is HELD and must be given back — an RpcSecurityPolicy field, a buffer bound, a one-probe gate, or a request the caller of a lifecycle method is awaiting
breaks: "one way a dead limit, the other way a DoS: an unbounded rise in handlers, or denial of service."
applied: [214, 215, 245, 266, 271, 351, 372, 382, 463, 467, 491, 494, 502, 508, 520, 733]
status: confirmed (round 494)
rank: 22
---

# RPC-05 — Where a concurrency limit is charged

## Shape

A new limit charges the resource at the wrong point of the lifecycle — or
charges the wrong thing, releases it at the wrong point, or never charges it.

## Detector

For every `RpcSecurityPolicy` field, where exactly it is checked: stream
admission, handler entry, dispatch. Then the limits that are NOT policy fields —
rounds 245 and 351 both found the defect in one: anything that holds a counter, a
byte total or a single slot and hands it back later. Grep for the give-back
(`= false`, `--`, `remove`) and ask which endings reach it.

Narrow to fields that HOLD state. Pure predicates cannot suffer this shape:
`maxMessageLengthBytes`, `maxHeaders`, `maxMetadataBytes`, `maxHeaderNameBytes`,
`maxHeaderValueBytes`, `maxMethodPathLength`, `maxMessagesPerChunk`,
`closeOnProtocolError`, and `maxBufferedBytes` (the parser's reassembly
threshold, `if (_state.available > _maxBufferedBytes) throw`). Covered so far:
`maxConcurrentHandlers` (round 214, P-06), the four fc fields (rounds 206-213;
212 fixed a leak), `maxActiveStreams` (round 212), `halfOpenStreamTimeout`
(round 205), the pre-method budget (round 215, P-07).

Also grep for listeners whose body is empty and doc comments explaining why a
subscription that consumes nothing must exist — each is a release somebody has
to remember.

## Ask

Charging at entry — is it a no-op against a burst? Charging at admission — does
it deny service to half-open streams? And: **enumerate the endings**, then check
each one reaches the release. WHAT does the limit charge, not only where? Who
else was charged when you were? Who is BLOCKED on the release? What is the
minimum number of times the charge runs for one call — if zero, the call is free?

Bench rules: hold arrivals open against the ceiling (a returning handler never
fills it; saturating the connection hides it — pace past the reclaim grace); a
bench for a SERVER limit must not give the ceiling to the client too
(`RpcChannelTransport.pair(policy:)` configures both ends).

## Evidence

30 calls past a ceiling of 3 when charged at entry; 8 metadata-only frames
refused every call for 60 s when charged at admission. Only dispatch works.
Both neighbours of the right charge point are measurably wrong, in opposite
directions, which is why this lens exists.

- **Round 114** — origin, imported from private memory after round 235. `maxActiveStreams` bounds live stream STATE, not running handlers: deadline reclaim frees the slot while an uncooperative handler keeps running, giving **37 concurrent handlers after 20 s** against `maxActiveStreams: 4` while `activeResponders` read 3-4. Closed by `maxConcurrentHandlers` (opt-in, charged at dispatch): 37 -> 4.
- **Round 116** — the release wrapper sat on the innermost handler, so a parked interceptor gave 2 live against a ceiling of 1; it now wraps the whole `handleUnary` / `handleClientStream` / `handleServerStream` / `handleBidirectionalStream` call at all 8 dispatch sites. **Three separable halves, so three canaries** — a never-released slot leaves the attack witness green while ordinary traffic fails. **When a new assertion fails, check the FIXTURE before the code.**
- **Round 205** — `halfOpenStreamTimeout`: 20 parked streams reclaimed to 0.
- **Round 214** — enumerated all sixteen fields; churn against a ceiling of three released in place on normal/throw/cancel/deadline, and read 0 with `_releaseHandlerSlot` ablated. **Charging is only half a lifecycle: enumerate the endings, not the happy path.** It wrongly listed `maxBufferedBytes` as stateful, corrected in round 215.
- **Round 215** — the pre-method budget's `endStream` ending holds bytes and is the reorder deferral, not a leak; shown with a short-timeout run and a release ablation. **A held resource is not a leaked one: shorten the bound that should release it, and if the number goes to zero it is a policy.** Recorded as C-20.
- **Round 245** — `BufferedBroadcastController`'s byte bound weighed `RpcTransportMessage.bufferedBytes`, payload only: metadata frames retained 256.0 MiB, stopped only by the event count; after, 15.9 MiB. **Ask WHAT a limit charges, not only WHERE; a dimension the peer controls and the weigher ignores is not a bound.** Saturation hid it: 43,908 calls produced exactly 8 handlers. `../probes/P-21-metadata-escapes-the-byte-bound.md`
- **Round 271** — `RpcHttpResponderTransport` released its own `_pending` on `bodyReadTimeout` but not the pipeline's stream: openStreams 8, ordinary call status 8. **A limit is released by whoever can still see the stream, not the layer that charged it.** `halfOpenStreamTimeout` bounds time while the attacker controls rate, and `RpcHttpServer` keeps one responder endpoint, an exception to C-29. `../probes/P-22-body-that-never-arrives.md`
- **Round 351** — the circuit breaker's one-slot `bool _probeInFlight`: a consumer cancel (`stream.first`, `take(n)`) reached none of the three releases, pinning the gate halfOpen (0/5 admitted). **Round 214's rule on a gate: enumerate the endings;** the give-away was a comment (U-01). The sibling `rpc_dart_opentelemetry` `_wrapWithSpan` ends in `onCancel`; one `grep -n onCancel` is the sweep (U-14). The control first varied two things at once. `../probes/P-43-cancelled-stream-probe.md`, `../rounds/351-the-ending-nobody-wired.md`; the neighbouring ending that answers wrongly is `../backlog/B-36-the-abandon-timer-fabricates-a-success.md`.
- **Round 463** — `RpcHttpCallerTransport` referenced `maxActiveStreams` nowhere: 12 admitted against 4, 12 requests at the server. **Before accepting a substitute mechanism (the `HttpClient` pool), measure it on the far side; the parked handler is the bench.** All four endings still released with the second site ablated: **a release site can be REDUNDANT, kept because the failure if coverage moves is a RATCHET.** `../rounds/463-the-ceiling-the-pool-did-not-cover.md`, `../probes/P-112-what-a-caller-ceiling-is-for.md`.
- **Round 467** — both refusals in `responder_pipeline` answered both frames of a new call (`[status=14, status=14]`, `[status=8, status=8]`). **A refusal has a lifecycle: decide, answer, record the id done** — the record ran a microtask late via `_detached`; `async` bodies run synchronously to the first `await`, so moving it above fixed sixteen call sites. `../rounds/467-a-refusal-that-answered-twice.md`, `../probes/P-106-what-a-late-frame-on-a-closed-stream-is-told.md`.
- **Round 491** — on HTTP/1.1 `releaseStreamId` drops the `Completer<Response>` shelf awaits; the deadline reclaim sent no trailer, so requests arrived 1, answered 0. **Ask what the method's caller is waiting for; when a comment explains why something is NOT sent, ask what else rode on it. A counter that a teardown decrements cannot report work the teardown abandoned** (`pendingRequests: 0`). `../probes/P-130-does-a-reclaimed-stream-answer-its-request.md`, `../rounds/491-the-call-ended-and-the-request-did-not.md`, B-100.
- **Round 494** — `_peerStreamIds` recorded any id `!_idsOnThisConnection.contains(id)`: heartbeats 0 -> 29, cancels 0 -> 50. **Measure a set against its invariant, not a size; a release cannot fix a wrong acquire** (the trailer arrives after release). Fixed by `m.methodPath != null`; **when a fix makes every witness read ZERO, the guard does most of the work** (`1`, then `0`). `../probes/P-132-does-the-peer-id-set-return-to-zero.md`, `../rounds/494-minting-is-what-a-methodpath-means.md`, B-103.
- **Round 502** — `RpcRateLimiter` charged client-stream and bidi per inbound message, so a bidi call sending none was free: 100 of 100 admitted against 5. **A charge driven by a repeating event has a zero case, and the zero case is a bypass.** The control caught the additive fix halving one-message calls; shipped cost is `max(1, messages)`. `../probes/P-140-what-the-rate-limiter-admits.md`, `../rounds/502-the-shape-that-was-never-admitted.md`, B-111.
- **Round 508** — `RpcChannelTransport` added every inbound message to a buffered broadcast, so `startCallerListening` existed only to drain it (`1001` replayed, then `0`). **That comment is the detector; the fix is to stop charging.** Check which SIDE is charged (`isClient ? id.isOdd : id.isEven`) and separate the things riding on one stream (`addError` still needs the subscription). `../probes/P-146-what-the-second-dispatch-costs.md`, `../rounds/508-work-added-to-undo-work.md`, B-117.
- **Round 520** — `finishSending` releases a unary client's slot while the call is outstanding: `maxActiveStreams` bounds request-SENDING on a client, outstanding calls on a server. **Measure a two-sided limit on each side SEPARATELY; keep the ambiguous run (`4 refused` vs `0 refused`) as the control; check which direction a fix's failure runs** — never releasing is worse than releasing early. `../probes/P-157-what-the-client-ceiling-counts.md`, `../rounds/520-two-sides-counting-different-things.md`, B-128.
