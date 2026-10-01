---
refines: U-19
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: policy fields are enforced by each transport separately
breaks: a security hole on the transport nobody picked.
applied: [205, 394, 414, 501, 504, 517, 518, 523, 524, 525, 540, 542, 543, 544, 545, 546, 547, 548, 553, 554, 556, 560, 563]
status: confirmed (round 554)
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

Round 524 shipped the fix: a running total INSIDE the header loop, so a megabyte of
legal headers is refused at 64 KiB rather than after all of it is resident — the same
accepted-versus-retained distinction round 506 made about the metadata frame check.

> **For a fix that TIGHTENS a limit, the guards are the whole review.** Four of them,
> and each blocks a different way of "fixing" it wrongly: metadata within the limit
> must still pass (or the check refuses everything); an oversized single header must
> still be refused for its OWN reason (or the new check swallows the old one); too many
> headers must still be refused BY COUNT (or two distinct faults collapse into one
> message); and a policy configured with a LARGER limit must admit correspondingly more
> — which is what proves the bound follows the field rather than a constant somebody
> inlined.

`../rounds/524-the-sum-nobody-was-taking.md`.

## Two limits on one quantity: measure the BAND, not either end (round 525)

A hardcoded 128 in `forClientRequest` against the policy's 1024 path limit. The
disagreement exists only between them, so neither number read alone shows anything —
`129` to roughly `1018` characters of service name is routable by the policy and
refused by the caller.

**So ask both questions per input and let the rows disagree.** "Would this be routed"
and "will this be built" in one table; the band is the finding, and a count of
refusals would have said nothing at all.

> **The control is an input past BOTH limits, where the answers turn negative
> together.** Without it, a column of "routable / refused" is equally consistent with
> the rig mislabelling one of the two checks. And short inputs where both answers are
> positive are the other half — they prove neither column is stuck.

> **A sibling disagreement is not always a one-liner, and say so when it is not.** The
> constant exists because `forClientRequest` is a STATIC with no policy in scope.
> Fixing it means changing a widely used signature, or removing the check and relying
> on the parse that already enforces the real limit — a different change with a
> different risk. And before either: what was the constant MEANT to be? Moving a
> validation limit without knowing is how it ends up wrong in the other direction.

`../probes/P-160-is-a-routable-name-callable.md`,
`../rounds/525-routable-and-uncallable.md`, B-198.

## Round 553 — the divergent sibling was a SHAPE, and the fix took three attempts

Not a policy field this time but a capability: unary could not take a gRPC frame split
across transport messages, where both streaming shapes could, over the same transport,
channel, codec and payload.

> **A sibling divergence that two rounds failed to close is usually blocked on a
> QUESTION nobody can answer, not on work nobody did.** Attempts 1 and 2 were both built
> in full and both reverted. The thing in the way was that `RpcMessageParser` returning
> nothing meant two different things — incomplete, and refused — and every design resting
> on the emptiness of that result reported a `maxMessageLengthBytes` refusal as a
> truncated request. The third attempt opened by adding the distinction, and it was one
> getter: the parser clears its buffer on every refusal, so leftover bytes already meant
> exactly one thing.

> **Ask the component that KNOWS, not the one that is convenient.** The predicate that
> carries the fix reads the parser's buffer, not the caller's own "awaiting" flag — which
> stays true while a later fragment is being processed, and answering a peer on that
> reading closed the responder out from under its own running handler. Silently, because
> a closed responder writes nothing.

> **A canary that PASSES can be a design finding.** Disabling the half-close answer
> changed nothing, which meant three sites were answering and a race chose between them.
> Removing the redundant one made each ordering have exactly one answer site — and only
> then did the canary fail, on an arm that had to be built because the existing one could
> not reach that branch.

`../rounds/553-the-parser-knew-all-along.md`,
`../probes/P-181-which-branch-took-the-fragment.md`, B-126.

## Round 554 — the same divergence one round later, and the fix was a PLACE

Round 553 fixed unary's half of this at the pipeline, and B-216 recorded that the other two
shapes still diverged on the same input: `server stream status 4` (its deadline),
`client stream got:0` (a SUCCESS reporting zero messages where the peer sent an incomplete one).

> **When N shapes disagree, look for the one component they all run through and put the rule
> THERE.** Three responders decided separately at three layers, which is why the first fix
> reached one of them. `StreamProcessor` owns the parser and every request side passes through
> it, so one helper made all three agree — and the two existing answer paths (a server-stream
> responder answering an error on its request stream, a client-stream handler's `await for`
> throwing) needed no change at all. The lead predicted the signal would have to cross the
> processor/pipeline seam; it did not, because the question is about the processor's own buffer.

> **A rule placed at one layer must cover every way that layer is ENTERED.** A half-close
> reaches a processor twice over — as a frame carrying end-of-stream, and as the bound message
> stream simply finishing — and two sites closed the request controller. Left apart, the answer
> would have depended on the shape of the FEED rather than on the request.

> **A witness covering two shapes in one test can only show one failure.** The canary stopped at
> the server-stream assertion and the `got:0` regression went unobserved; split per shape, both
> appear with their own message. Where a fix spans several shapes, so should the witnesses.

`../rounds/554-one-rule-where-the-parser-is.md`, B-216, B-218.

## Round 556 — the divergent thing was a PUBSPEC, and the lens's own audience was the question

Same shape outside the code: five transports each declaring an `rpc_dart` floor separately, where
seven of eight swept core symbols are in no published core at all — `IRpcReconnectableTransport`,
used by all five, appears at the `rpc_dart-6.3.0` tag only inside this journal's files.

> **A green gate is silent about anything the workspace resolves locally.** The pub workspace always
> takes core from source, so `analyze`, `test` and `prepare` all pass over a floor no published core
> satisfies. Where a property only binds OUTSIDE the build you run, the gate is not weak evidence —
> it is no evidence, and the detector has to be the published artefact (`git show <tag>`).

> **Check who the victim is before grading severity.** This lens keeps finding "the transport nobody
> picked", and that framing assumes somebody picks one. The owner's answer here was that nobody but
> they consume these packages, which drops the finding to near zero — and the same question hangs
> over much of the audit intake, whose failures are written for third-party implementers and pub.dev
> resolvers. Ask it first; it is cheaper than the round.

> **Running the repo's own bulk tool is not the same as fixing what you measured.**
> `bump:rpc_dart` raises all 20 packages by design; it was run where 9 had been proven to need it,
> on the reasoning that a type-level sweep could not prove the rest safe. That reasoning is a gap in
> the method, not evidence about those packages — and it widened a change past its measurement.

`../rounds/556-no-published-core-satisfies-any-floor.md`, B-154.

## Round 560 — one cause, two transports, two unrecognisably different disasters

A start guard whose flag is assigned after the bind's await, so two concurrent callers both pass it.
Filed against the HTTP/1.1 server; present in the HTTP/2 one too.

```
http    TWO concurrent   bound + threw     isRunning=true   endpoints=0  call -> status 14
http2   TWO concurrent   started + threw   isRunning=false  call -> ok:x  PORT STILL BOUND
```

> **The same cause can produce opposite symptoms, and that is why this lens sweeps by SHAPE rather
> than by symptom.** http ends up bound and answering UNAVAILABLE behind a flag that says healthy;
> http2 ends up bound and serving traffic behind a flag that says dead, where `stop()` gives up on
> exactly that flag and the listener leaks for the life of the process. Searching for either
> description finds nothing in the other file. Searching for "flag assigned after the await" finds
> both.

> **An observable that lives only outside the process.** http2's `stop()` returns normally and
> `isRunning` is already false, so every in-process check says the server is down. The only thing
> that can see the leak is a bind attempt on the port from outside. When a teardown's whole job is
> to release an OS resource, the witness has to ask the OS.

> **A claim flag has three release points, not one**: the failure path, the teardown, and never on
> success. The fix was written with the teardown release in one package and without it in the other,
> and the missing one refused the first restart — caught by an existing lifecycle test, not by the
> new witness.

`../rounds/560-the-guard-was-behind-the-await.md`,
`../probes/P-184-a-start-guard-behind-its-own-await.md`, B-151.

## Round 563 — a bound that covered one phase of an operation and not the others

`_proxyHandshakeTimeout` bounds a proxy's CONNECT response. The socket connect and the TLS handshake in
the same method had nothing, so a dropped SYN waited on the OS.

```
  refused, bound at 2s        OSError after 10ms
  black-holed, bound at 2s    OSError after 1730ms
  black-holed, bound OFF      STILL PENDING at the probe cap of 8s
```

> **A field whose doc names a risk is evidence that somebody saw the risk, not that they covered it.**
> `_proxyHandshakeTimeout`'s own comment says "Unbounded, this hangs an application at STARTUP: connect()
> is what it awaits" — and it bounds one of the three things `connect()` awaits. The sibling that exists
> is where to look for the ones that do not.

> **`timeout:` and `.timeout()` are not the same fix.** The wrapper abandons the future while the
> operation carries on, which for a connect means a socket nobody holds and nobody closes. Where the
> library offers its own parameter, the wrapper is a leak wearing a fix's clothes.

> **A default longer than the probe is indistinguishable from no default.** Capped at 12 s against a 30 s
> default, the arm read `STILL PENDING` with the fix in place — the exact output the defect produces.
> Drive the knob by argument; assert the default separately if at all.

`../rounds/563-the-bound-the-comment-described-and-did-not-provide.md`,
`../probes/P-186-what-bounds-a-connect-into-a-hole.md`, B-182.
