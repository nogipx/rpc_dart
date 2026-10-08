# Loop backlog

What a lead is and how it links to the rest — [../LOOP.md](../LOOP.md). The
record format — `../../skills/evidence-loop/specs/backlog-item.md`.

**Closed leads live in [archive/ARCHIVE.md](archive/ARCHIVE.md)** — 128 of them.

**The `B-14x`–`B-19x` leads came from one external audit, and its severity claims do not hold — read
[../checked/C-61-the-audit-intakes-severity-claims-do-not-hold.md](../checked/C-61-the-audit-intakes-severity-claims-do-not-hold.md)
before taking one.** Six have been measured and not one was exactly as filed: true-and-worthless
(B-154), refuted (B-178), true-and-severe (B-184), the wrong method named (B-151), a crash claim
resting on a comment about a different call (B-192), accurate (B-182). Treat a `## Why it matters`
line as a hypothesis owing a witness, not as a severity.

**Nothing here ranks leads for a future round.** Choosing a target is the round's own judgement,
recorded in its `## Target`, and the severity bar lives in `config.md`.

Closed leads are not deleted and several have been re-opened by a later measurement; that
file says how to read one. Keeping them here is what round 232 warns against: an
archive kept inline reads as live state to anything that does not parse a status
field.

**This file now holds ONLY live leads**, which it had not since round 444. Rounds
445-540 closed 63 leads where they lay on the belief that moving one needed `mv`
and the allowlist did not carry it; B-74's line had said so since round 445. The
round-540 pass tried `git mv` and it runs, so the debt is paid and the belief was
never tested — which is L-13's shape, a reason copied forward without being
re-read.

## State, as of round 540

`loop.py status` is the source; this is here so a reader does not have to run it.

```
open                 69
awaiting owner        0
owner decisions not yet carried out   10
archived (closed)   128
```

**`awaiting owner` is at zero for the first time since the audit intake arrived.** The
`owner_review` passes at round 540 put all fourteen questions: ten were decided to act on,
three closed on the measurement (B-119, B-127, B-130), and one was signed off without
closing its lead (B-116). The ten are now the round's first target, ahead of the rank
order below, because `status` announces them that way.

**Every live lead is in the audit-intake section below.** Rounds 485-540 worked it
in rank order and B-145 is next. Two of its leads were REOPENED in the round-540
pass (B-138, B-141), because each had closed on the item a round measured while its
own body still declared work — and nine remainders were split out as B-201..B-209.

**That shape is now a check rather than a habit.** `loop.py lint` warns on a closed
lead whose `## Still open` has a body, and `next` lists them under **CLOSED BUT
UNFINISHED**; a `## Still open` section is for context, never for a task, because
`next` lists leads by `status:` and a closed one is invisible to it. Ten leads were
in that state when the check was written.

**The line order below is the rank**: decided-and-ready first, then by damage
class. `loop.py status` prints them in this order.

**State is on the line, not in a heading.** Each line opens with the checkbox
its `status:` demands — `[ ]` open, `[?]` awaiting owner, `[+]` decided and not
yet carried out — and `loop.py lint` checks the two against each other. Do NOT
group the leads under status headings: that was the previous notation and it
drifted silently, because nothing read it. One journal carried an "Awaiting an
owner decision" section of fourteen leads while every one of them said
`status: open`, and `loop.py status` printed "Awaiting owner: 0" beside it.

**Before parking a lead as a question for the owner, check that both branches
actually exist.** B-28 sat for 68 rounds framed as "either pace metadata or
bound the buffer, ask the owner" — and one of the two was never available, because
HTTP/2 exempts HEADERS from flow control for a deadlock reason the spec states.
What looked like a trade about library behaviour was a question the protocol had
already answered.

**A lead records the reason it was deferred, and nothing re-reads that reason
when the world moves.** Round 415 took the owner through every live lead in one
pass and six closed without work; round 444 found a lead whose own body said it
was spent and whose remaining item was a reachable defect. `loop.py stale` ages
a lead against its PATHS, which is a different thing from ageing its argument.

**The round-445 review decided every lead that existed THEN**, written into each
lead's `## Owner decision` (the status says `round 445` because that is the round
the review rode in on; the questions were put before the round chose its target).
Read it before starting: several are "measure FIRST, then decide the fix", which
is a decision about what the round does, not a licence to skip to the fix. Its
exceptions were B-10, whose deferral stood, and B-88, filed after the review.

**That review does not reach the audit intake below**, which arrived later and
whose leads mostly still carry `## Owner decision: —`. Fourteen were raised to
`awaiting owner` by the round that measured them — a real question with a measurement
behind it, which is a different thing from never having been asked — and the round-540
`owner_review` passes decided all fourteen: B-106, B-107, B-111, B-116, B-119, B-120,
B-126, B-127, B-128, B-130, B-195, B-199, B-200, B-209. Each decision is in its lead's
`## Owner decision`, in the owner's terms, and the index line above carries its
constraint.
B-85 was missed in that review's own intake and decided immediately after —
which is the same failure the review was warned about: verify the whole list
before reporting on it.

**And a decision is only as good as the tree it was read on.** The review
decided B-74 on a body that had been stale for three days: the defect was fixed
by `663cccec` the day after the lead was written, and because that commit was
never recorded as a round, every tool here went on reporting the lead as live.
Round 445 found it by reading the code first. L-13 is the rule; check the paths
against `git log` before carrying a decision out.

## From the external audit of 2026-09-28 — intake `8253fe8a`, 101 leads; 81 live, with nine split out since

A full read of core `rpc_dart` and all six transports (websocket, HTTP/1.1,
isolate, wasm with its Swift and Kotlin halves, in-memory, http2), transport
findings re-checked against the code. **Nothing was measured**: the auditing
container had no Dart SDK, so every lead carries `probe: none` and names the
witness a round owes it first — any of them may be refuted by that witness.

**That warning has been earned repeatedly.** Of the leads measured so far, the
witness refuted a claim outright in B-119, B-127, B-141 and parts of B-129 and
B-139; and in B-131, B-133 and B-144 the claim held while the lead's own FIX
SKETCH did not. **Two of the `*-cleanup-items` grab-bags grade their items
backwards** — in B-129 and B-139 alike, what the lead flagged as "behaviour, not
style" cost nothing measurable while a real defect sat inside a bulleted
sub-list. Split one before working it.

Owner decisions: `## Owner decision` is still `—` on most of these, since the
round-445 review predates the intake. Twelve were raised to `awaiting owner` by
the round that measured them; the preamble lists them.
Leads already on this journal were not re-filed: B-38 (iOS recv loop), B-93 /
C-56 (the two shims), C-23 (Android guest rejections), B-35 (`finish()` into the
zone), B-71, B-75, B-86 — where the audit found something NEXT to one of them the
new lead says so.

**Ranked, not grouped**: B-94..B-107 are the damage-class leaders in rank order
(one event failing unrelated calls, silent loss, unbounded memory, hangs). From
B-108 on the order follows the audit's package priority — core, websocket,
HTTP/1.1, isolate, wasm, in-memory, http2 — with defects before hygiene inside
each. The `*-cleanup-items` leads bundle numbered hygiene items per package so
none is lost; split one out when a round takes an item.

**Refuted during the audit, so not filed**: "http2 `close()` reports a cut
stream as a clean finish" — `CallProcessor`'s and `UnaryCaller`'s `onDone` turn
a bare close into UNAVAILABLE; "the unawaited catch blocks in the bidi pipeline
can kill the process" — `StreamProcessor.sendError` never throws; "the CBOR
4-byte branch is signed on dart2js" — dart2js compiles `<<`/`|` unsigned (the
wrong claim is `protocol.dart:141`'s comment, filed inside B-129).

- [x] ~~**[B-102](B-102-the-android-wasm-sandbox-death-goes-unreported-when-idle.md)**~~ closed (round 684) — Android wasm: a sandbox that dies while the driver is parked is never reported
- [x] ~~**[B-221](B-221-a-parked-send-reports-success-after-a-peer-reset.md)**~~ closed (round 568) — by owner decision, 2026-10-07 — a parked send reports success after a peer reset, and the pump outlives the reset
- [x] ~~**[B-220](B-220-the-responder-mints-a-trace-id-it-could-derive.md)**~~ closed (round 566) — the responder mints a trace id it could derive, for any peer that sends no trace header
- [x] ~~**[B-219](B-219-a-health-detail-went-missing-under-load.md)**~~ closed (round 592) — a health detail answered null under load
- [x] ~~**[B-218](B-218-the-other-half-closes-are-unmeasured.md)**~~ closed (round 619) — the other half-closes, and what a decoded backlog actually costs
- [x] ~~**[B-217](B-217-the-connection-wide-buffer-has-no-depth.md)**~~ closed (round 600) — the connection-wide buffer has no depth either
- [x] ~~**[B-106](archive/B-106-zero-copy-has-no-backpressure.md)**~~ CLOSED (round 550) — **the ceiling is in.** `queue cost: HOLDING -33 MiB / MINTING 270 MiB / MINTING at depth 64, 71 MiB` — the bound lands where configured, and costs the holding shape nothing, which is the decision's premise holding up. `RpcStreamBufferLedger` gained an EVENT dimension beside its byte one, both charged per message with whichever is reached first binding; `maxBufferedMessagesPerStream` defaults to 1024 and its doc states what it counts and why nothing else. **Three places needed the count and not the bytes**, each a defect alone: `release` returns the event charge even for a zero-byte message (or a zero-copy stream is admitted `limitEvents` times then refused for ever — round 536's inversion), `forget`/`clear` drop it, and `trackedStreams` counts either dimension. **Found on the way: a SECOND queue**, now B-217. `P-178`. Previously: awaiting owner (round 549) — **the measurement is DONE and the question is narrower.** `queue cost: HOLDING -1 MiB / MINTING 313 MiB` for 400 objects of 1 MiB with no consumer. Both claims about a direct object are true, of different shapes: queuing one the process already holds costs a pointer exactly as the code says, and queuing one nobody else holds costs its whole payload. The claim was never wrong — it was about the SHAPE, and nothing said so. **The decision's fork cannot be resolved here**: which shape an application uses is a fact about applications, not this library. **But it may not need resolving** — a per-stream queue-depth ceiling is correct under BOTH arms (on MINTING it is the only bound on memory; on HOLDING it costs nothing real, since the objects exist either way and the queue's own cost measures `-1 MiB`). So the question put back is: add that ceiling, given it is safe either way? It is a new public policy field, hence asked rather than taken. **Two rig errors worth reading before re-measuring**: a zero-filled `Uint8List` is not resident until written (400 MiB of allocation moved RSS by 6), and both arms in one process made the second's baseline the first's high-water mark. `P-178`. Previously: DECIDED by the owner (round 540): **MEASURE FIRST** — separate a MINTING producer from a HOLDING one, then decide. The owner's question is the right one and the record did not answer it: `bufferedBytes` is 0 for a `directPayload` and the code says queuing one "costs a pointer", which is TRUE for an object the process already retains — and round 497's arm mints a fresh 1 KiB per message precisely so nothing else holds it. Two arms on P-135's rig: a handler that creates per message (the queue is everything produced) against one that sends an already-retained object (the queue really is pointers). If the second shape is rare, in-memory's severity rises and a count-based ceiling is obvious; if it is common, the bound belongs only where the object is COPIED, i.e. isolate. **Settled already, do not re-derive**: `SendPort.send` deep-copies all but deeply-immutable values and the transport's own doc says `supportsZeroCopy` there means "sendDirectObject works" — so on isolate the pointer argument fails in principle and that half needs only a decision. **The nominal per-object weight is OFF the table** as a fiction; if a bound is wanted it is a per-stream EVENT ceiling, a queue depth, which invents nothing. `P-135`. Superseded: * awaiting owner (round 497), high — **CONFIRMED**, and only by varying the WINDOW: shrinking it 64-fold moves the codec path 32x (`189274 -> 5960`) and zero-copy not at all (`247722 -> 274289`). The four obvious arms say both paths run away equally, which is the opposite conclusion — `checked/C-19` records that the library does not throttle producers at all, so "the producer got ahead" carries no information. **Both halves of the fix sketch are decisions**: a nominal per-object weight is new public policy against `RpcSecurityPolicy`'s own warning about fields nothing enforces, and parking on credit reverses rounds 208 and 214. Options, measurement already done: a nominal weight, a per-stream EVENT ceiling (no fictional byte count needed), or accept and document. Isolate half unmeasured. `P-135`
- [x] ~~**[B-198](B-198-the-caller-refuses-names-the-server-routes.md)**~~ closed (round 602) — the caller refuses service names the server routes
- [x] ~~**[B-248](B-248-http1-drops-the-error-details.md)**~~ closed (round 681) — the HTTP/1.1 caller drops the error details
- [x] ~~**[B-249](B-249-an-oversized-in-process-message-reads-as-internal.md)**~~ closed (round 676) — an oversized message on memory and isolate reads as INTERNAL
- [x] ~~**[B-250](B-250-auto-mode-skips-codecs-and-limits-on-unary-only.md)**~~ closed (round 677) — `auto` skips the codecs and the size limit, on unary only
- [x] ~~**[B-251](B-251-one-oversized-websocket-request-fails-the-connection.md)**~~ closed (round 680) — one oversized websocket request fails the whole connection as UNKNOWN
- [x] ~~**[B-252](B-252-a-dead-peer-is-9-on-three-transports-and-14-on-two.md)**~~ closed (round 678) — a call after the peer died is 9 on three transports and 14 on two
- [x] ~~**[B-253](B-253-request-metadata-edges-differ-by-transport.md)**~~ closed (round 679) — request metadata edges differ by transport
- [x] ~~**[B-254](B-254-a-client-stream-to-a-wasm-guest-fails.md)**~~ closed (round 682) — a client-stream call to a dart2wasm guest fails with INTERNAL
- [x] ~~**[B-255](B-255-ten-thousand-guest-frames-fail-on-android.md)**~~ closed (round 683) — 10k frames from a guest stream fail on Android
- [x] ~~**[B-256](B-256-js-backed-bytes-on-the-web-under-dart2wasm.md)**~~ closed (round 699) — JS-backed bytes on the web under dart2wasm
- [x] ~~**[B-257](B-257-small-messages-trip-the-depth-cap.md)**~~ closed (round 709) — small messages trip the depth cap
- [x] ~~**[B-258](B-258-the-window-outgrows-the-stream-buffer.md)**~~ closed (round 710) — the window outgrows the stream buffer
- [x] ~~**[B-259](B-259-pre-bind-requests-are-credited-twice.md)**~~ closed (round 711) — pre-bind requests are credited twice
- [x] ~~**[B-260](B-260-a-silent-h2-client-kills-the-server.md)**~~ closed (round 712) — a silent h2 client kills the server
- [x] ~~**[B-261](B-261-h2-uploads-meet-the-depth-without-credit.md)**~~ closed (round 715) — h2 uploads meet the depth without credit
- [x] ~~**[B-262](B-262-the-connection-window-alone-has-no-message-credit.md)**~~ closed (round 715) — the connection window alone has no message credit
- [x] ~~**[B-263](B-263-a-ping-flood-grows-the-websocket-server.md)**~~ closed (round 713) — a ping flood grows the websocket server
- [x] ~~**[B-264](B-264-an-oversized-h1-stream-keeps-its-slot.md)**~~ closed (round 714) — an oversized h1 stream keeps its slot
- [x] ~~**[B-265](B-265-an-h1-client-cancel-never-reaches-the-server.md)**~~ closed (round 715) — an h1 client cancel never reaches the server
- [x] ~~**[B-266](B-266-audit-minor-items.md)**~~ closed (round 716) — audit minor items
- [x] ~~**[B-247](B-247-a-call-after-reconnect-saw-an-inactive-connection.md)**~~ closed (round 671) — by owner decision, 2026-10-07 — the first call after reconnect() saw an inactive connection
- [x] ~~**[B-246](B-246-an-http1-request-failure-retires-the-client-connection.md)**~~ closed (round 668) — an HTTP/1.1 request failure retires the client connection
- [x] ~~**[B-245](B-245-peer-middleware-cannot-tell-direction.md)**~~ closed (round 700) — middleware on a peer cannot tell an outgoing call from an incoming one
- [x] ~~**[B-244](B-244-a-responder-interceptors-deadline-is-not-enforced.md)**~~ closed (round 701) — a deadline set by a responder interceptor is not enforced
- [x] ~~**[B-243](B-243-stream-ids-collide-across-reconnects-after-a-wrap.md)**~~ closed (round 661) — stream ids collide across reconnects after the id space wraps
- [x] ~~**[B-242](B-242-honest-metadata-closes-the-server-connection.md)**~~ closed (round 660) — metadata within the policy closes the server connection
- [x] ~~**[B-241](B-241-websocket-answers-lost-under-gate-load.md)**~~ closed (round 670) — a websocket answer lost to a closed socket, under gate load only
- [x] ~~**[B-196](B-196-the-web-worker-suite-flakes-at-load.md)**~~ closed (round 702) — `test:web` flakes at the load stage on the web-worker suite
- [x] ~~**[B-195](archive/B-195-the-window-is-much-looser-than-its-number.md)**~~ CLOSED (round 552) — **the decision is carried out and this lead's premise was an artefact of its own probe.** The window charges WIRE bytes and is exact: `66 x 993 B = 65 538` against a 65 536-byte window, `15 B/msg` across a 64x sweep. P-135's `_Blob.toJson` emits `{'n': 1024}`, so every "1 KiB message" was 11 bytes on the wire and `185 MiB` is `count x a size that never crossed it` — the overshoot is the CODEC's expansion factor, and 66 messages hold 66 KiB or 1.0 MiB behind one unchanged window because the field cannot see what a message decodes to. **Two arms the lead lacked, either of which changes the conclusion**: a second settle time (`4372` at 1 s and at 2 s is a bound, where `251292 -> 487856` with the field off is a rate) and wire size held while decoded size varies. **And carrying the decision out found the field switched OFF in a legal configuration**: with `initialSendWindowBytes: null` a server stream was unbounded for life, `sendCredit: 0`, because an inbound end-of-stream was treated as the end of the CALL and dropped the stream's flow-control state — on a peer-opened stream it is their half-close, and a server stream half-closes immediately. FIXED, one condition. The remainder is **B-218**. `P-180`. Previously: DECIDED by the owner (round 540): **document what the number means** — the window is credit for what is UNCONSUMED, not a ceiling on residency. Not the tightening: that reaches into rounds 208 and 214, which chose to refuse a stalled call rather than throttle a producer, and would cost throughput wherever clients rely on the slack. **More than a comment, though**: count the multiplier and say what the ratio depends on rather than quoting one figure, **and canary that the field bounds anything at all** — set the window tiny and show retention moves; round 497's own table already has that arm (64x smaller window moved the codec path 32x). A documentation round with no canary is the shape this journal refuses. Verified present at review time: `_window => _policy.flowControlWindowBytes`. No behaviour CHANGELOG, but the field's doc is public surface and its audience is the operator who set 4 MiB to bound memory. Previously (mis-marked): open (round 497), owner decision, high — split out of B-106's CONTROL: the per-stream window is engaged (32x between two window sizes) and an order of magnitude looser than its own number — `185 MiB` retained on one stream at a `4 MiB` window, `5.8 MiB` at `64 KiB`. The policy field's doc promises exactly what these rows disprove, naming this scenario and a 527 MB measurement. Likely credit returned on ARRIVAL rather than on application consumption (RPC-01's shape, round 352's proxy), **not verified**. Two branches and a precedent pointing away from the obvious one: tighten it (reversing rounds 208/214) or correct the doc
- [x] ~~**[B-107](archive/B-107-hidden-sixty-second-timeouts.md)**~~ CLOSED (round 548) — **FIXED: all four shapes now agree.** `no deadline: unary 60.0s / clientStream 60.0s / serverStream 65.0s` became `65.0s / 65.0s / 65.0s`, and that number is the PROBE's budget rather than a bound. Both constants removed and the effective timeout made nullable, **including the zero-copy unary branch** this lead listed as never measured and which carried the same fallback. The control still holds: with a 500 ms deadline the header is sent, the type is `RpcDeadlineExceededException` and the handler is cancelled. `cancelled` goes 1 -> 0 on the no-deadline rows and that is correct — round 498 taught the caller to notify when it ABANDONED a call, and there is no abandonment now. **The witness cannot see the shipped 60 s** (a 400 ms assertion cannot), so the canaries restore each fallback at 250 ms and the 60 s instance stays the probe's; stated in the test. Three comments describing the bound as current behaviour were corrected. Previously: DECIDED by the owner (round 540): **REMOVE the implicit barrier** — no deadline means no timeout, as the streaming shapes already behave. A hidden limit the server never hears about is worse than no limit: it turns a slow answer into a client-side error while the server still believes the call is live, and it does that unevenly. Verified present at review time (`_noDeadlineFallback` and `?? const Duration(seconds: 60)`). **BREAKING** — a caller relying on the implicit 60 s gets a hanging call where it had an error, so the CHANGELOG line is as much the deliverable as the code, and it must name the remedy: pass a deadline. Witness: a call with no deadline against a server that never answers, which today fails at 60 s. Canary: the same call WITH a deadline must still fail at it. Previously: awaiting owner (round 498), high — **every claim CONFIRMED**: with no deadline `unary 60.0s`, `clientStream 60.0s`, `serverStream 65.0s` (the probe's budget — nothing bounds it), `grpc-timeout=[null]`, `cancelled=0`; against a 500 ms-deadline control where the header is sent, the type is `RpcDeadlineExceededException` and `cancelled=1`. **The abandonment half is FIXED in round 498** (`cancelled 0 -> 1`) — no decision was needed for it, and the duty was named in `notifyPeerOfAbort`'s own doc. **What is left is the policy**: no implicit bound anywhere (gRPC's behaviour; existing callers start hanging) or one documented default on every shape sent as `grpc-timeout` (picks a number for everyone, and would bound legitimately long-lived streams). Also open: the exception type differs by origin, and the zero-copy unary path was not measured. `P-136`
- [x] ~~**[B-213](B-213-the-rate-limiter-resolves-its-counters-per-message.md)**~~ closed (round 618) — the rate limiter resolves its counters once per message
- [x] ~~**[B-116](B-116-every-inbound-message-is-copied-three-times.md)**~~ closed (round 614) — channel transports copy each inbound message three or four times, and frame it twice
- [x] ~~**[B-119](B-119-a-unary-call-costs-five-frames.md)**~~ closed (round 540) — a unary call is five frames, three of them JSON-encoded metadata
- [x] ~~**[B-120](B-120-per-call-context-and-id-cost.md)**~~ closed (round 621) — each call copies both context maps five to seven times and draws 12 bytes of OS entropy
- [x] ~~**[B-124](B-124-peer-triggered-warnings-fire-per-frame.md)**~~ closed (round 605) — warnings a peer can trigger fire on every frame, and application errors log at error twice
- [x] ~~**[B-126](archive/B-126-unary-assumes-one-message-per-transport-frame.md)**~~ CLOSED (round 553) — **FIXED on the third attempt, and the blocker attempt 2 died on was a GETTER.** The distinction was already inside the parser: every refusal path calls `clear()` before throwing, so leftover bytes mean "incomplete" and nothing else — `holdsPartialFrame` is `available > 0`, exact by construction, with eight cases pinning it. `fragmented -> got:64`, `mid-frame half-close -> status 3`, `LATE mid-frame half-close -> status 3`, `whole frames -> got:64`, `REFUSED at a 1 KiB responder policy -> status 8 'max: 1029'`, `streaming shapes -> got:64`. **One predicate carries the design and it is not the obvious one**: `isAwaitingRequest` asks the parser rather than the pipeline's bookkeeping, which stays true while a later fragment is being PROCESSED — answering the peer on that reading closed the responder out from under its own handler, silently, because a closed responder writes nothing. Found with `P-181`, a tracer: three statuses had been read and none said where the fragment went; printing every record showed it delivered AND parsed with no answer after it. **Canary B passing is what improved the design** — a half-close was answered at THREE sites and whichever won a race answered, so the redundant one went and each ordering now has exactly one answer site; it also forced a new arm, since a half-close arriving after the responder begins waiting is a different branch from one carried on the fragment. The answer is RETURNED rather than left on state, which makes round 547's trap unreachable. Behaviour change beyond the lead: a truncated unary request answers INVALID_ARGUMENT where it answered INTERNAL, which is the accurate status. Unwitnessed and stated in the code: the pre-bind drain loop's second iteration. `P-181`, `P-155`. Previously: **ATTEMPT 2 REVERTED (round 547) — the decision stands, and now carries its blocking constraint.** Built in full, both required witnesses green (`each frame split in two -> unary got:64`; `peer stops mid-frame -> status 3`), then the gate went red and one failure has no fix inside the design: a 32 MB payload compressed against a **1 MB configured policy** answered `status 3 'closed mid-message'` where it must answer RESOURCE_EXHAUSTED naming `max: 1048576`. **The approach reads `RpcMessageParser` returning NO messages as "incomplete", and it also means "REFUSED"** — a security control reporting the wrong status, worse than the INTERNAL being removed. A third attempt must take that distinction FROM the parser. **Settled by canary, so it is not re-derived**: the mid-frame half-close answer prevents the HANG (round 518's regression reproduced by ablating it), the fragment ROUTING makes the call succeed rather than fail cleanly, and **"feed every buffered message" is UNWITNESSED** (an arm was built for it; ablating it changed nothing). Trap recorded: `requestHandled` read state that `handleMessage`'s `finally` removes, so a COMPLETED call read as "still arriving" and the pipeline skipped its teardown — surfacing as an undisposed call scope and an unreleased http2 endpoint. Witnesses kept SKIPPED in the tree with the condition in the skip; `P-155` gained `truncate` and `reorderMetadata` arms. Previously: DECIDED by the owner (round 540): **take the unary lifecycle change**, option 2, against this lead's own recommendation — tolerating a fragmenting transport is a capability the library should have, and unary being the one shape that cannot is the wrong asymmetry to document as intended. **Round 518's revert is the constraint**: accumulating in the unary responder ALONE turns an immediate INTERNAL into a HANG, because two further layers drop the later fragment, so all three parts (feed every buffered pre-bind message; keep the request stream alive to completion or half-close; route post-bind data to a responder with `listensToTransport: false`) are load-bearing. The witness needs BOTH arms — a fragmented frame answered, and a peer that stops mid-frame answered with a status rather than left waiting. Previously (superseded): awaitine.md)** awaiting owner (round 518), high — **CONFIRMED**: against a channel that splits every DATA frame in two, `unary status 13 "Failed to extract message from payload"` while `server stream got:64` and `client stream got:64` in the same run, sharing transport, channel, codec and payload. **The sketch's accumulate half was implemented and REVERTED** — with the responder fixed, unary stopped returning INTERNAL and started hanging to its deadline, because the later fragment has no route: the pipeline hands over only `preBindMessages.first`, and `_cleanupStream` runs immediately after. **Three layers, and this lead names two; a partial fix is a regression, not a smaller improvement** — a hang is worse than a clear error. `lib/` is byte-identical to its committed state. **The owner's choice**: document the invariant on `IRpcTransport` (cheap, and round 507 set the precedent by stating exactly this kind of contract on `IRpcChannel.incoming`), or pay for a unary lifecycle change on a hot path for a case no shipped transport produces. The lead's own note argues for the first. `P-155`
- [x] ~~**[B-210](B-210-a-server-stream-arms-nine-timers-before-any-deadline.md)**~~ closed (round 606) — a server stream arms nine timers before any deadline exists
- [x] ~~**[B-127](B-127-three-timers-per-server-deadline.md)**~~ closed (round 540) — a server call arms three timers and two token listeners for one deadline
- [x] ~~**[B-129](B-129-core-cleanup-items.md)**~~ closed (round 623) — core: dead code, misleading docs and duplicated helpers
- [x] ~~**[B-130](B-130-the-websocket-heartbeat-releases-on-the-new-inner.md)**~~ closed (round 540) — websocket heartbeat releases its id on whatever `_inner` is current by then
- [x] ~~**[B-212](B-212-the-streaming-shapes-tail-cleanup-is-unmeasured.md)**~~ closed (round 616) — the streaming shapes and the race round 541 did not price
- [x] ~~**[B-216](archive/B-216-a-server-stream-hangs-on-a-truncated-frame.md)**~~ CLOSED (round 554) — **FIXED in one place for all three shapes.** `server stream status 4 -> status 3`, `client stream got:0 -> status 3`, unary unchanged. **The rule went where the PARSER is**: `StreamProcessor` owns it and is the single thing all three request sides run through, so `_endRequests()` raises INVALID_ARGUMENT into the request controller before closing it when `holdsPartialFrame` holds — and nothing else needed changing, because the server-stream responder already answers an error on its request stream and a client-stream handler's `await for` throws into a path that already answers. Both endings route through the one helper, since a half-close reaches a processor as a frame carrying end-of-stream AND as the bound message stream finishing; left apart the answer would depend on the shape of the FEED. **This lead's "hard part is where" was answered by round 553's getter** — it predicted the signal must cross the processor/pipeline seam, and it does not, because the question is about the processor's own buffer. The witness had to be SPLIT per shape: as one test it stopped at the server-stream assertion and the client-stream regression went unobserved. Bidi is fixed by construction and measured by nothing — that column is in B-218. `P-155`. Previously: open (round 547), bench, medium — **a peer that half-closes MID-FRAME leaves a server stream waiting to its deadline**, where unary answers and a client stream completes: `unary status 3 (with round 547's reverted fix) / server stream status 4: Deadline exceeded / client stream got:0`. **Independent of that round** — the server-stream column reads `status 4` with its fix in place and with it ablated, because the guard was gated on `is UnaryResponder`. The shape was always this way; nothing looked until the arm existed, and the arm exists because B-126's decision demanded it. A peer sending half a message costs the server a live call until its deadline, or for the life of the connection if the caller set none. **The third column deserves its own question**: a truncated frame read as ZERO messages makes the call SUCCEED, telling the handler the peer sent nothing when it sent an incomplete something. The hard part is where to fix it — the processor owns the parse and the pipeline owns the half-close, the same seam round 547 had to cross for unary. `P-155`
- [x] ~~**[B-224](B-224-the-wire-byte-window-test-flakes-under-the-gates-concurrency.md)**~~ closed (round 589) — the suite's timing assertions break when the gate oversubscribes its cores
- [x] ~~**[B-215](B-215-the-chrome-suites-fail-differently-every-run.md)**~~ closed (round 702) — `rpc_dart_isolate`'s Chrome suites fail differently every run
- [x] ~~**[B-214](B-214-compare-and-keep-smaller-has-no-web-arm.md)**~~ closed (round 607) — compare-and-keep-smaller has no web arm
- [x] ~~**[B-226](B-226-the-bind-relies-on-microtask-order.md)**~~ closed (round 617) — a peer call's bind relies on microtask order
- [x] ~~**[B-225](B-225-what-the-connection-total-does-not-see.md)**~~ closed (round 610) — what the connection total does not see
- [x] ~~**[B-138](B-138-the-websocket-channel-has-no-read-backpressure.md)**~~ closed (round 595) — the websocket channel does not propagate pause to the socket
- [x] ~~**[B-139](B-139-websocket-cleanup-items.md)**~~ closed (round 599) — websocket: smaller defects and hygiene
- [x] ~~**[B-141](B-141-the-http1-body-timeout-and-reject-drain-are-dead.md)**~~ closed (round 663) — HTTP/1.1 responder: the body-read timeout does not stop the read, and `_reject`'s drain always fails
- [x] ~~**[B-143](B-143-http1-close-closes-an-injected-client.md)**~~ closed (round 587) — HTTP/1.1 caller closes an `http.Client` it did not create

### Remainders split out of closed leads (round-540 bookkeeping)

Each of these was measured as part of a lead that then CLOSED on the item a round fixed, leaving the rest in a `## Still open` section that nothing reads. `loop.py` now reports that shape — `lint` warns, `next` lists it under CLOSED BUT UNFINISHED — and these nine are what it found on the first run. The parents keep the history; their sections now say `## Split out to B-20N`.

- [x] ~~**[B-207](B-207-a-zlib-sink-is-never-closed-when-the-limit-throws.md)**~~ closed (round 591) — the zlib sink is never closed when the size limit throws
- [x] ~~**[B-202](B-202-a-whole-frame-in-one-chunk-is-resident-before-any-check.md)**~~ closed (round 611) — a frame delivered in one chunk is resident before any limit can refuse it
- [x] ~~**[B-204](B-204-the-bridge-stack-under-every-streaming-message.md)**~~ closed (round 622) — the bridge stack under every streaming message, none of it varied
- [x] ~~**[B-203](B-203-the-websocket-wrappers-second-broadcast.md)**~~ closed (round 596) — the websocket wrapper re-broadcasts every frame the core transport already routed
- [x] ~~**[B-206](B-206-comparing-sizes-costs-cpu-and-two-copies.md)**~~ closed (round 620) — comparing sizes fixes the growth and pays for it in CPU nobody measured
- [x] ~~**[B-205](B-205-a-log-scope-is-allocated-per-call.md)**~~ closed (round 608) — `child()` and `withContext()` allocate a scope and concatenate a name per call
- [x] ~~**[B-208](B-208-the-generic-drain-still-polls.md)**~~ closed (round 612) — the generic drain still polls, so there are still two of them
- [x] ~~**[B-201](B-201-path-filters-upstream-trusted-the-old-grammar.md)**~~ closed (round 613) — path filters upstream trusted a grammar the responder has since tightened
- [x] ~~**[B-145](B-145-http1-response-headers-are-not-validated.md)**~~ closed (round 581) — HTTP/1.1 caller passes response headers into metadata unchecked
- [x] ~~**[B-146](B-146-http1-two-content-types.md)**~~ closed (round 582) — HTTP/1.1 responder emits two content-type values
- [x] ~~**[B-147](B-147-http1-status-comments-are-stale.md)**~~ closed (round 583) — HTTP/1.1 comments describe a status table core no longer has
- [x] ~~**[B-222](B-222-a-too-large-body-is-uploaded-three-times.md)**~~ closed (round 669) — a body over the ceiling is uploaded three times
- [x] ~~**[B-148](B-148-the-http1-request-body-is-a-list-of-int.md)**~~ closed (round 585) — HTTP/1.1 caller buffers the request body in a `List<int>` and copies it again
- [x] ~~**[B-149](B-149-http1-sends-te-trailers.md)**~~ closed (round 586) — HTTP/1.1 caller sets `te: trailers`, which nothing uses and browsers refuse
- [x] ~~**[B-150](B-150-the-standalone-http1-responder-has-no-limits.md)**~~ closed (round 584) — the standalone HTTP/1.1 responder defaults to no body limit and no slow-client bound
- [x] ~~**[B-223](B-223-a-whole-body-deadline-cannot-separate-slow-from-stalled.md)**~~ closed (round 673) — a whole-body deadline cannot separate a slow upload from a stalled one
- [x] ~~**[B-151](B-151-http1-server-lifecycle-defects.md)**~~ closed (round 674) — RpcHttpServer lifecycle: crash on order, racing starts, forced close before 503, polling drain
- [x] ~~**[B-152](B-152-http1-caller-cleanup-items.md)**~~ closed (round 672) — HTTP/1.1 caller: smaller defects and hygiene
- [x] ~~**[B-153](B-153-http1-cors-policy-items.md)**~~ closed (round 671) — CORS policy: a process-wide warning flag, duplicate headers, per-response rebuilds, a mutable allow-list
- [x] ~~**[B-154](archive/B-154-transport-pubspec-floors-are-below-the-core-api-they-use.md)**~~ CLOSED on the owner's instruction (round 556) — decided, and the work is a release's rather than a round's; left open it read as a standing `Owner decisions not yet carried out: 1`. **The number is `6.4.0` and it happens at RELEASE.** The bump was applied across all 20 packages via step 1b and reverted on the owner's instruction, because **nobody but the owner consumes these packages** — and a floor binds only a resolver OUTSIDE this workspace, so the failure has nobody to happen to. The minor was chosen with its cost stated: 18 of the 82 core commits since 6.3.0 carry `!`, so on `^6.0.0` a user auto-upgrades into breaking changes. **That re-grading is the round's real output**: much of the ~49-lead audit intake is written for an audience that may be empty, and whether to re-grade it for a single consumer is asked and unanswered. A method error is recorded too — `bump:rpc_dart` raises all 20 by design and was run rather than editing the 9 proven to need it, which widened a change past its measurement. Measurement below, now permanent at near-zero cost. — **CONFIRMED and far larger than filed: EVERY transport declares a floor that NO published core satisfies.** Swept every public type added to core since the lowest floor, grepped each across the transports, checked each against every published tag: **seven of eight are in no published core at all** — not at the declared floor and not at 6.3.0, the newest. `IRpcReconnectableTransport` is referenced by all five transports and at the `rpc_dart-6.3.0` tag appears only inside this journal's files, nowhere in the code; `RpcClosedException` (http, http2, websocket), `RpcNoConnectionException` (http2, websocket), `RpcMetadataViolation` (http2), `RpcContentTypeValidation` + `maxFramedMessageBytes` + `isAcceptableContentType` (http, http2) likewise. Published as they stand each transport resolves 6.3.0 and fails to compile. `IRpcAdvisoryChannelError` is the one row that is RIGHT (core 6.1.0, websocket's floor `>=6.1.0`) and stands in for a canary — without it the table would read the same whether the method could tell the two cases apart. **The fix sketch cannot be carried out as written**: `bump:rpc_dart` has nowhere to point, because core's pubspec still reads `6.3.0` and that version is tagged, so the tree gained public API with no bump. **Owner's, because both steps are versioning**: bump core to `6.4.0` FIRST, then raise every floor to it (step 1b). Bites only when the transports are published; nothing is broken in the repository today. **The gate cannot see this class and never will** — the workspace resolves core from local source. Not swept: `data`/`notify`/`blob`, which declare their own ranges, and added MEMBERS rather than types (the two field/method entries above are here only because the audit named them)
- [x] ~~**[B-155](B-155-isolate-spawn-failure-leaks-ports.md)**~~ closed (round 577) — isolate: three ReceivePorts stay open when Isolate.spawn throws
- [x] ~~**[B-156](B-156-isolate-transferable-typed-data-is-not-zero-copy.md)**~~ closed (round 578) — isolate: TransferableTypedData.fromList copies, contrary to the class doc
- [x] ~~**[B-157](B-157-isolate-startup-budget-and-handshake.md)**~~ closed (round 579) — by owner decision, 2026-10-07 — isolate: startup can take twice startupTimeout, over a handshake with a spare port; the kill comment has the order backwards
- [x] ~~**[B-158](B-158-isolate-decode-errors-escape-the-listener.md)**~~ closed (round 698) — cleanup commit by owner decision — isolate (VM and web): a malformed frame throws inside the port listener
- [x] ~~**[B-159](B-159-isolate-fragility-and-dead-parameters.md)**~~ closed (round 580) — by owner decision, 2026-10-07 — isolate: a spawned closure in a large scope, implicit startup ordering, dead parameters and branches
- [x] ~~**[B-160](B-160-isolate-web-bytes-travel-as-js-arrays.md)**~~ closed (round 706) — isolate on web: payload bytes cross as arrays of boxed numbers
- [x] ~~**[B-161](B-161-isolate-web-any-worker-error-closes-the-connection.md)**~~ closed (round 705) — isolate on web: any `messageerror` or worker `error` event closes the transport
- [x] ~~**[B-162](B-162-isolate-web-ondone-starts-the-entrypoint.md)**~~ closed (round 705) — isolate on web: the worker's onDone fallback starts the user entrypoint on a closing transport
- [x] ~~**[B-163](B-163-isolate-web-early-grant-on-a-module-worker.md)**~~ closed (round 704) — isolate on web: the connection-window grant may be lost on a dart2wasm module worker
- [x] ~~**[B-164](B-164-isolate-web-and-stub-cleanup-items.md)**~~ closed (round 698) — cleanup commit by owner decision — isolate web/stub: hygiene
- [x] ~~**[B-165](B-165-wasm-frames-before-the-dart-handler-are-lost.md)**~~ closed (round 675) — wasm: bytes pushed before the Dart handler (or the guest's handler) is installed are dropped
- [x] ~~**[B-166](B-166-the-android-wasm-sandbox-is-cached-forever.md)**~~ closed (round 685) — Android wasm: the sandbox (or its failure) is cached for the process lifetime
- [x] ~~**[B-167](B-167-ios-wasm-replaces-queuemicrotask.md)**~~ closed (round 686) — iOS wasm: the boot script replaces WKWebView's native queueMicrotask
- [x] ~~**[B-168](B-168-wasm-byte-transport-cost.md)**~~ closed (round 708) — wasm: one HTTP request per frame on iOS, base64 plus a fresh script per frame on Android, a polling driver
- [x] ~~**[B-169](B-169-wasm-timer-polyfills.md)**~~ closed (round 687) — wasm: the timer polyfills are O(n) per call and break event-loop ordering
- [x] ~~**[B-170](B-170-wasm-console-lines-lose-their-level.md)**~~ closed (round 665) — wasm: multi-line console messages lose their level prefix
- [x] ~~**[B-171](B-171-wasm-api-surface-claims.md)**~~ closed (round 688) — wasm: the barrel claims to be runtime-agnostic and needs Flutter; `canRunDartWasm` ignores Android's requirements
- [x] ~~**[B-172](B-172-wasm-cleanup-items.md)**~~ closed (round 698) — round 689 and a cleanup commit by owner decision — wasm: smaller native and Dart defects
- [x] ~~**[B-173](B-173-the-direct-channel-drops-frames-before-subscribe.md)**~~ closed (round 574) — RpcDirectMultiplexedChannel is a sync broadcast that starts pumping in its constructor
- [x] ~~**[B-174](B-174-in-memory-payload-aliasing-and-close-asymmetry.md)**~~ closed (round 590) — in-memory: payloads are aliased and delivered later; close drops frames asymmetrically; two names for one factory
- [x] ~~**[B-175](B-175-the-http2-cancel-opens-a-phantom-stream.md)**~~ closed (round 569) — http2 caller: a cancel for an unknown id opens a new /Unknown/Unknown stream
- [x] ~~**[B-176](B-176-http2-reconnect-strands-subscribers.md)**~~ closed (round 572) — http2 caller: reconnect() cancels stream subscriptions without telling their consumers
- [x] ~~**[B-177](B-177-http2-goaway-is-invisible-through-a-proxy.md)**~~ closed (round 690) — http2 caller: GOAWAY is never detected on the proxy path
- [x] ~~**[B-178](archive/B-178-http2-discard-connection-lets-an-error-reach-the-zone.md)**~~ CLOSED (round 557) — **severity REFUTED, prose fixed.** Four arms silent (`healthy / socket destroyed`, `future dropped / awaited`) against a POSITIVE CONTROL where `finish()` escapes with `ZONE: Bad state: Cannot add event after closing`. So dropping `terminate()`'s future costs nothing observable and the fix sketch would have handled an error that does not arrive — though `TransportConnection.terminate` IS declared to return one, which is what made this cheap to report and cheap to be wrong about. **The prose half holds**: the comment's reason is true and belongs to `finish()`, a call this method does not make and exists to avoid; round 347 lost a round to the same confusion, so it now names which call it means. The two `terminate()` arms went into `finish_throws_into_the_zone_test` beside the `finish()` one, deliberately — four silent rows mean "safe" only if something in the same rig is known to escape, and the probe's first version had no working control (a bare TCP peer, against which `finish()` never completed). Not covered: the reconnect path, package:http2 2.3.1, and the transport's other terminate/finish sites. `P-182`
- [x] ~~**[B-179](B-179-http2-keepalive-death-status-and-a-late-callback.md)**~~ closed (round 691) — http2 caller: keepalive death yields FAILED_PRECONDITION, and a late probe can mark a new connection dead
- [x] ~~**[B-180](B-180-http2-server-first-end-leaves-the-local-side-open.md)**~~ closed (round 570) — http2 caller: when the server ends first, the request side is never ended or reset
- [x] ~~**[B-181](B-181-http2-policy-is-applied-to-foreign-trailers.md)**~~ closed (round 567) — http2 caller: our header policy is enforced on the peer's trailers and destroys the real status
- [x] ~~**[B-182](B-182-http2-connect-has-no-timeouts.md)**~~ closed (round 693) — http2 caller: no timeout on connect, TLS handshake or connect-to-proxy
- [x] ~~**[B-183](B-183-http2-proxy-and-addressing-defects.md)**~~ closed (round 698) — http2 caller: proxy auth, IPv6, :authority and ALPN
- [x] ~~**[B-184](B-184-http2-send-message-races-after-its-await.md)**~~ closed (round 565) — http2 caller: sendMessage and finishSending race a disposed or parked pump
- [x] ~~**[B-185](B-185-http2-missing-status-is-retryable.md)**~~ closed (round 571) — http2 caller: a clean end without grpc-status becomes retryable UNAVAILABLE
- [x] ~~**[B-186](B-186-http2-overrun-error-arrives-before-data.md)**~~ closed (round 666) — http2 caller: on a window overrun the error is delivered before the data that caused it
- [x] ~~**[B-187](B-187-http2-close-sleeps-fifty-ms.md)**~~ closed (round 696) — http2 caller and responder: close() sleeps a fixed 50 ms
- [x] ~~**[B-188](B-188-http2-a-failed-response-keeps-downloading.md)**~~ closed (round 664) — http2 caller: non-200 or wrong content-type fails the call but keeps reading the body
- [x] ~~**[B-189](B-189-http2-terminal-events-are-delivered-twice.md)**~~ closed (round 667) — by owner decision, 2026-10-07 — http2: terminal events delivered twice; self-cancellation logged at error; late RST after release
- [x] ~~**[B-190](B-190-http2-responder-lifecycle-defects.md)**~~ closed (round 695) — by owner decision, 2026-10-07 — http2 responder: an unowned subscription, status-less endings, a lost parked trailer, a health that lies
- [x] ~~**[B-191](B-191-http2-rejected-stream-sends-error-text.md)**~~ closed (round 662) — http2 responder: `_answerRejectedStream` puts a foreign error's text on the wire
- [x] ~~**[B-192](B-192-http2-server-double-close-and-accept-crash.md)**~~ closed (round 564) — the rest as a cleanup commit, by owner decision — http2 server: onConnectionClosed fires twice; a socket read in the accept path can kill the isolate
- [x] ~~**[B-193](B-193-http2-header-helpers.md)**~~ closed (round 703) — http2 common: headers validated twice, rebuilt per call, walked two or three times
- [x] ~~**[B-194](B-194-http2-cleanup-items.md)**~~ closed (round 698) — cleanup commit by owner decision — http2: smaller defects and hygiene

## From the independent audit of 2026-10-02 — seven auditors, every finding reproduced by a round before filing

- [x] ~~**[B-227](B-227-the-connections-policy-is-a-second-copy.md)**~~ closed (round 635) — the connections' policy is a second copy of the server's
- [x] ~~**[B-228](B-228-a-typed-int-list-is-cut-to-bytes.md)**~~ closed (round 625) — a typed int list is cut to bytes
- [x] ~~**[B-229](B-229-a-tiny-message-pins-its-whole-chunk.md)**~~ closed (round 636) — a tiny message pins its whole chunk
- [x] ~~**[B-230](B-230-a-server-stream-with-no-request-is-never-answered.md)**~~ closed (round 627) — a server-stream with no request is never answered
- [x] ~~**[B-231](B-231-a-bare-prefix-reads-as-a-clean-end.md)**~~ closed (round 629) — a bare prefix reads as a clean end
- [x] ~~**[B-232](B-232-a-server-stream-that-fails-locally-never-tells-the-server.md)**~~ closed (round 626) — a server-stream that fails locally never tells the server
- [x] ~~**[B-233](B-233-a-cancel-still-waits-for-the-reconnect.md)**~~ closed (round 628) — a cancel still waits for the reconnect
- [x] ~~**[B-234](B-234-a-server-deadline-answers-the-wrong-status.md)**~~ closed (round 638) — a server deadline answers the wrong status
- [x] ~~**[B-235](B-235-a-second-message-on-a-single-message-side-is-accepted.md)**~~ closed (round 637) — a second message on a single-message side is accepted
- [ ] **[B-270](B-270-the-web-gate-loses-its-first-browser-test.md)** open — the web gate loses its first browser test
- [ ] **[B-268](B-268-a-constructed-websocket-transport-reports-online-early.md)** open — a transport built on an unconnected channel reports online, then crashes
- [ ] **[B-269](B-269-an-accept-and-close-endpoint-flaps-online.md)** open — an endpoint that accepts TCP and closes it flaps the connection online
- [ ] **[B-267](B-267-the-reconnecting-proxy-hides-the-connection-total.md)** open — the reconnecting proxy hides the connection total
- [x] ~~**[B-236](B-236-an-undecodable-response-has-no-status.md)**~~ closed (round 631) — an undecodable response has no status
- [x] ~~**[B-237](B-237-a-trimmed-message-splits-a-character.md)**~~ closed (round 630) — a trimmed message splits a character
- [x] ~~**[B-238](B-238-a-closed-caller-throws-before-the-future.md)**~~ closed (round 632) — a closed caller throws before the Future
- [x] ~~**[B-239](B-239-the-guides-teach-apis-that-do-not-exist.md)**~~ closed (round 633) — the guides teach APIs that do not exist
- [x] ~~**[B-240](B-240-three-cbor-edges-off-the-rfc.md)**~~ closed (round 634) — three CBOR edges off the RFC

## Notes kept from intakes that are fully closed

No live lead is below this line. Three sections used to sit here — device/service,
the duplication sweep, "the rest" — and every lead in them is archived. What is kept
is the part that is not about a lead: operating truth about this machine, and one
pointer.

**The device blockers are gone, and the original reason was never true.**
*"`xcrun simctl` is outside the agent's allowlist"* was written in round 357 and
copied forward untested for over a hundred rounds. It runs. The real obstacle was
different and fixable: registered simulators whose data directory was missing from
disk (`Unable to boot device because it cannot be located on disk`). Round 470
hesitated to run `xcrun simctl erase` because erasing destroys a simulator's
contents; round 472 found `CoreSimulator/Devices` did not exist at all, so there was
nothing to destroy. Both platforms now run `melos run test:wasm:device` — iOS `+27`,
Android `+24 ~2` — and Android's first run ever was RED on a test wrong since round
416.

**The service images are cached locally** (`postgres:16-alpine`, `redis:7-alpine`,
`minio/minio:latest`). Round 471's `unauthorized` came from asking for a PULL of a
tag that is not the cached one; `docker images` settles it in one command. All four
service suites run green.

**B-70 keeps the duplication sweep's routing table and the six claims that died on
the re-read** — read it before re-deriving any of that intake. Its 36 items produced
22 leads, all archived, the last in round 484.
