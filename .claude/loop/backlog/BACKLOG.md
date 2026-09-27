# Loop backlog

What a lead is and how it links to the rest — [../LOOP.md](../LOOP.md). The
record format — `../../skills/evidence-loop/specs/backlog-item.md`.

**Closed leads live in [archive/ARCHIVE.md](archive/ARCHIVE.md)** — 65 of them,
moved out of this file after round 444. They are not deleted and several have
been re-opened by a later measurement; that file says how to read one. Keeping
them here is what round 232 warns against: an archive kept inline reads as live
state to anything that does not parse a status field.

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

**Every lead but two now carries an owner decision**, taken in one review during
round 445 and written into each lead's `## Owner decision` (the status says
`round 445` because that is the round the review rode in on; the questions were
put before the round chose its target). Read it before starting: several are
"measure FIRST, then decide the fix", which is a decision about what the round
does, not a licence to skip to the fix. The exceptions are B-10, whose deferral
stands, and B-88, which round 445 filed after the review.
B-85 was missed in that review's own intake and decided immediately after —
which is the same failure the review was warned about: verify the whole list
before reporting on it.

**And a decision is only as good as the tree it was read on.** The review
decided B-74 on a body that had been stale for three days: the defect was fixed
by `663cccec` the day after the lead was written, and because that commit was
never recorded as a round, every tool here went on reporting the lead as live.
Round 445 found it by reading the code first. L-13 is the rule; check the paths
against `git log` before carrying a decision out.

## Waiting on a device or a service

Decided, not carried out. None of these is blocked on a judgement.

- [+] **[B-38](B-38-ios-recv-loop-dies-silently.md)** decided (round 415) — the iOS recv loop gives up silently and Android already fixed this; its own comment describes the iOS behaviour. The four-step patch, the witness design and the two traps are in the lead. **The OWNER boots the simulator** — `xcrun simctl` and `open -a Simulator` are outside the agent's allowlist and five `flutter emulators --launch` attempts registered nothing. Shipping on `analyze:native` alone was offered and DECLINED; round 348 established what a gate never shown to fail is worth, and this is a native change whose whole defect is that it fails silently. Run BOTH platforms
- [+] **[B-03](B-03-wasm-no-package-swift.md)** decided (round 415) — add `Package.swift` now, not when SPM becomes the Flutter default: the cost is the same either way and nothing in a round's ordinary work would detect the day the default flips. A DEVICE round — the privacy manifest goes in BOTH manifests or the `resource_bundles` defect already caught once comes back, and the evidence is a BUILT app, so `pod install` then `test:wasm:device` on iOS twice: once under CocoaPods as the control, once with SPM
- [+] **[B-33](B-33-blob-adapters-disagree-on-a-missing-blob.md)** decided (round 415) — unify all four adapters. In scope because B-10's deferral was NARROWED: it covers going LOOKING in data/notify/blob, not fixing a defect already measured there. Order matters — **measure the four-row matrix FIRST** (minio and sqlite were never compared, so "which answer is right" is otherwise decided on half the data), then write the answer onto `IBlobRepository.deleteBlob`, then one test per adapter. **Needs the excluded services up**, or it unifies two adapters and guesses about two
- [+] **[B-35](B-35-finish-throws-into-the-zone.md)** re-decided after round 426 — **leave it, report upstream, no behaviour change.** Nothing in this library reaches the state, measured over connect / call / close / close-again with the finish budget forced to 1 ms and to zero, so the guard's trade (every async error from that connection rerouted) buys nothing. The characterisation test stays as what closes this the day the dependency stops throwing. **The only work left is filing the upstream issue.** Do not re-derive the guard as new — only a REACHABLE path re-opens it

## From the duplication sweep — split out of B-70 after round 444

One intake, `ff930001`, 36 items. Seven closed (9, 22, 28, 30 in round 415; 23
and 34 in 419; **5 in 444**, which is what refuted "the copies all agree"), item
14 belongs to B-56, and the rest are below. **B-70 keeps the routing table and
the six claims that died on the re-read** — read it before re-deriving any of
this. Ranked by damage class; round 444 named B-72, B-73 and B-85 as its own
top three, and B-74 is ranked above them here on the strength of round 366.

- [x] ~~**[B-74](B-74-a-trailer-can-overtake-a-parked-data-frame.md)**~~ closed (round 445) — the `sendMetadata` half was fixed by `663cccec` the day after this lead was written, never recorded as a round, so every tool here reported it as live for three days and the owner decided it on a dead body. Round 445 measured all five ending sites (P-99), fixed `sendDirectObject`, and left the rest as B-88. **The file is still here rather than in `archive/`**: moving it needs `mv`, which rule zero forbids, so the archival is the owner's one-line job
- [ ] **[B-88](B-88-the-fast-path-ending-was-never-reached.md)** open (round 445), bench — `sendMessage`'s UNPARKED branch ends a stream without claiming the ending, and the probe read **0 of 200 attempts** against it. **That zero is VOID, not clean**: the fast path fires only on `credit > 0` and a parked frame means credit is negative, so the preconditions exclude each other except in the single turn a grant lands — every attempt re-measured the parked branch instead. `tryConsume` never consults `_sendWaiters`, so the window is real; reaching it needs `RpcFlowController` driven directly. No caller in this library gets there (the only `sendMessage(end)` is a unary request, sole payload of its stream), so the exposure is a third party on the public transport. **Do not add the guard without a witness** — round 445 wrote it and dropped it, as 366 did before it
- [x] ~~**[B-72](B-72-context-header-limits-are-a-second-home.md)**~~ closed (round 446) — `RpcContext` held four private header limits numerically EQUAL to the policy defaults and reachable from no policy, `break`ing out at the ceiling with no signal. **Measured: raised to 512 the context still kept 128, and the call SUCCEEDED with 73 of 200 headers missing** (P-100). Size is the policy's alone now, and it throws. The lead's open question is answered — a transport DOES re-check, which is what made handing size over possible. It cost a prior deliberate decision: `f876d602` had made these caps effective on purpose, and the reversal came only after re-measuring the sentence it rested on. The remaining cost, feedback moving from build time to send time, is in the round under `## Not fixed`. **File not moved to `archive/`**: `mv` is outside the allowlist
- [+] **[B-86](B-86-the-end-flag-is-gated-on-the-status-on-one-path-only.md)** decided, cost — http2's DATA path will not end a stream before the status is known and says why in a comment; the HEADERS path is a bare `isEndOfStream: message.endStream`. Same damage class as B-62 and round 429: a stream that ends clean with no status is indistinguishable from a server that finished, so a short read is reported as success. Decision: reachability first, then the check goes in CORE at the consumer boundary — once, for every transport, which covers the UNPROVEN HTTP/1.1 half without proving it. Reuse P-97
- [+] **[B-81](B-81-two-cancel-orderings-each-justified-by-a-comment.md)** decided, cost — two cancel orderings, and **each carries a comment defending itself while one describes the other's bug**: "never throws" is not "never hangs", and the sibling's comment names the exact transport class that hangs that way. A hang, not a style question. Decision: bench both paths first, then ONE shared notify-then-teardown with a BOUNDED await — neither existing ordering is the one to copy. U-01 — a comment justifying deliberateness is a lead, not a closed door
- [+] **[B-76](B-76-three-reconnect-machines-three-answers-to-id-reuse.md)** decided, cost — websocket, http2 and `_ReconnectingTransportProxy` each solve stream-id reuse differently (a Set of live ids / never resetting `_nextStreamId` / a watermark), and the `_disconnected`-during-the-factory-await fix exists in ONE of them, above a comment describing what the other shape costs: *"sends accepted and dropped silently"*. Decision: port the guard to the other two FIRST, then make the three machines one — and do not stop after step one. Adjacent to B-21, not covered by it
- [+] **[B-77](B-77-three-content-type-behaviours-in-three-layers.md)** decided, cost — HTTP/1.1 rejects an ABSENT content-type, core accepts absent and refuses only a wrong value, and the http2 responder validates it NOWHERE. Same request, three verdicts, decided by which transport it arrived on. **Round 444 is adjacent and did not settle this** — it fixed the caller side, which made the disagreement reachable from an ordinary context. Decision: ONE shared validator plus a `contentTypeValidation: lenient | strict` policy key, default lenient (today's core rule) so nothing breaks now, strict as the default in the next major
- [+] **[B-73](B-73-the-deadline-disposer-is-caller-side-only.md)** decided, bench — `_setupDeadlineMonitoring` exists once, in the CALLER-side `CallProcessor`; the responder-side `StreamProcessor` has no deadline disposer, and the caller half's own doc says why one is needed. **NOT established as a defect** — the responder may bound the deadline by another route and nobody has looked. Decision: measure in the lead's three-question order, and if it is unbounded the disposer goes somewhere BOTH halves inherit, not into a fourth copy
- [+] **[B-75](B-75-the-http1-caller-has-no-active-stream-ceiling.md)** decided, cost — the HTTP/1.1 caller has **no `maxActiveStreams` check at all**, zero references, while core bounds `_activeStreams` and http2 bounds `_reservedStreams` and then applies a SECOND ceiling to `_streamParsers`. Decision (shared with B-79 and B-80): **measure whether the limit is meaningful here, then apply it uniformly** — consistency beats not adding a refusal, and a meaningless limit closes as a negative plus a doc line. Read RPC-05 and C-29 first
- [+] **[B-78](B-78-ensuregrpcframe-guesses-whether-data-is-framed.md)** decided, cost — `ensureGrpcFrame` decides whether a payload is already framed by PARSING its first five bytes and checking the declared length; a payload that satisfies that is returned unchanged and its first five bytes are then read as a header. A heuristic over application-controlled bytes, failing silently. Decision: reachability first — and if reachable, CARRY the already-framed fact (B-62's shape); a tighter heuristic is declined
- [+] **[B-79](B-79-bufferedbytes-is-charged-in-core-and-nowhere-in-http2.md)** decided, cost — core meters `bufferedBytes` in five places and is explicit that metadata counts toward it; the string does not appear anywhere in `rpc_dart_http2/lib`. Decision (shared with B-75 and B-80): measure first — if `dart:io` has already committed the peak, the answer is a DOC LINE, not a counter, because a limit that fires after residency is not a limit. If a bound is needed, prefer the http2 flow-control window. RPC-17 and C-29 first
- [+] **[B-80](B-80-the-five-byte-prefix-rule-never-reaches-an-http-body.md)** decided, cost — the "+5 bytes of prefix" rule is stated twice, both times in core, under a comment explaining that without it the effective limit "becomes `maxMessageLengthBytes - 5`, rejecting a message at exactly the limit". Neither HTTP package references `maxMessageLengthBytes` at all. Decision (shared with B-75 and B-79): **first establish which limit an HTTP body is checked against**, if any — the missing +5 is moot otherwise; and if a bound lands, the rule goes in ONE shared accessor, not a third copy
- [+] **[B-82](B-82-eleven-case-sensitive-encoding-comparisons.md)** decided, cost — the compression registry normalises with `trim().toLowerCase()`; **eleven sites outside it compare a raw header against the lower-case constant**, so `Identity` is a different codec to each. The count is 11, not the ~12 the sweep claimed. Decision: measure what happens today first (UNIMPLEMENTED is fine, decompressing against a codec that does not exist is not), then ONE shared normalising accessor — and do NOT normalise inbound metadata in place. Needs a hand-built peer; L-10 applies
- [+] **[B-83](B-83-the-drain-refusal-is-ordered-against-its-siblings-rule.md)** decided, cost — the drain refusal tests BEFORE the closed-stream guard; the ceiling refusal sits AFTER it and carries a comment explaining that it must. The drain branch has no comment and gets the opposite order, so it is either an undocumented specialisation or the bug the other comment exists to prevent. Decision: run the two-row bench, then align with the sibling — or, if the order turns out deliberate, ship the missing comment instead
- [+] **[B-85](B-85-a-default-written-twice-and-a-shim-in-two-languages.md)** decided, cost — every policy default is written twice, constructor against `fromMap`, literal repeated — and `fromMap` is how a policy crosses an isolate or worker boundary, so the two ends of one process would run on different limits. **The copies AGREE today**, so the failure mode is a future edit. Decision: the Dart half only, and ONE source for the defaults plus the test — a test alone was declined, because it detects the drift without preventing it. The native half (the JS shim carried as strings in both Swift and Kotlin) stays a separate, device-bound job
- [+] **[B-84](B-84-three-cleanup-blocks-with-different-subsets.md)** decided, cost — three stream-teardown blocks in the http2 caller, each adding something the others do not (`_fcForget`, `_streams.remove`, `_streamSubscriptions.remove`) over a shared core. **The sweep's counts were wrong** — 3 and 4, not 5 and 3. The weakest of the remainder. Decision: take it as VERIFICATION — answer the two measurable questions; both clean closes it as a negative in `checked/`, and cosmetic unification on its own is declined
- [+] **[B-87](B-87-the-sweeps-own-negatives-were-never-verified.md)** decided, cost — the sweep's own "already shared" list of nine, **never checked by anyone**. The half where being wrong is most expensive: a false negative here is a divergence nobody looks for again, because it is written down as settled. `drainUntilIdle` is the precedent — the loop was shared and the COUNT feeding it was not, which is how a graceful drain completed instantly with no error. Decision: all nine in one pass, prefer B-63 where it overlaps, write the negative for each that holds. A read, not a bench

## The rest

- [+] **[B-71](B-71-a-browser-websocket-client-cannot-detect-a-half-open-path.md)** decided, risk — a browser WebSocket client has no liveness signal on a half-open path: the API exposes neither the ping interval nor the OUTCOME, so a missing pong never reaches the page and does not close the socket the way `dart:io` does. **Round 442 spent option 1** by repairing the docs, which had asserted the opposite in two places. Decision: option 3, OPT-IN — an application-level heartbeat on the existing `RpcEndpointPingExchange`, web only, off by default, ideally driven by `pingInterval` so the parameter finally means the same thing on both platforms. Always-on and refuse-loudly are declined
- [ ] **[B-10](B-10-layers-without-lenses.md)** open, deferred by owner (223, **narrowed** in the backlog review) — three layers of the project have no lens at all. The deferral covers going LOOKING in `data`, `notify` and `blob`; it does NOT cover fixing a defect already measured and written down there, which is what unblocked B-33 and B-46
