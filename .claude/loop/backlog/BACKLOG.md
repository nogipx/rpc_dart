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

- [ ] **[B-74](B-74-a-trailer-can-overtake-a-parked-data-frame.md)** open, cost — **only one of four send paths waits for a credit-parked frame.** `finishSending` consults `_finishedStreams` and awaits a parked send; `sendMetadata(endStream: true)` goes straight to `_channel.send` and marks finished AFTER, so a trailer can overtake a DATA frame still parked in `_fcAwaitCredit`. **Same class as round 366**, which came in from a real user as `Declared length 2442197 does not match received 524288 bytes`, fifteen times, no reconnect in the logs. Reuse P-58's shape: an in-memory pair answers "never parks" in every row
- [ ] **[B-72](B-72-context-header-limits-are-a-second-home.md)** open, cost — `RpcContext` declares four private header limits numerically EQUAL to the policy defaults and wired to nothing; `_sanitizeHeaders` `continue`s past an over-long header and `break`s at the ceiling, discarding the remainder with no signal. Raise `maxHeaders` and the context still truncates at 128. **The equality is what hides it.** B-67's shape: a knob that is monotone downward only
- [ ] **[B-86](B-86-the-end-flag-is-gated-on-the-status-on-one-path-only.md)** open, cost — http2's DATA path will not end a stream before the status is known and says why in a comment; the HEADERS path is a bare `isEndOfStream: message.endStream`. Same damage class as B-62 and round 429: a stream that ends clean with no status is indistinguishable from a server that finished, so a short read is reported as success. **The HTTP/1.1 half is UNPROVEN** — the original sweep overstated it, and the corrected version is in the lead. Reuse P-97
- [ ] **[B-81](B-81-two-cancel-orderings-each-justified-by-a-comment.md)** open, cost — two cancel orderings, and **each carries a comment defending itself while one describes the other's bug**: "never throws" is not "never hangs", and the sibling's comment names the exact transport class that hangs that way. A hang, not a style question. U-01 — a comment justifying deliberateness is a lead, not a closed door
- [ ] **[B-76](B-76-three-reconnect-machines-three-answers-to-id-reuse.md)** open, cost — websocket, http2 and `_ReconnectingTransportProxy` each solve stream-id reuse differently (a Set of live ids / never resetting `_nextStreamId` / a watermark), and the `_disconnected`-during-the-factory-await fix exists in ONE of them, above a comment describing what the other shape costs: *"sends accepted and dropped silently"*. Adjacent to B-21, not covered by it
- [ ] **[B-77](B-77-three-content-type-behaviours-in-three-layers.md)** open, cost — HTTP/1.1 rejects an ABSENT content-type, core accepts absent and refuses only a wrong value, and the http2 responder validates it NOWHERE. Same request, three verdicts, decided by which transport it arrived on. **Round 444 is adjacent and did not settle this** — it fixed the caller side, which made the disagreement reachable from an ordinary context. The gRPC spec is the tiebreaker and refusing an absent header is a compatibility break, so this is a behaviour decision
- [ ] **[B-73](B-73-the-deadline-disposer-is-caller-side-only.md)** open, bench — `_setupDeadlineMonitoring` exists once, in the CALLER-side `CallProcessor`; the responder-side `StreamProcessor` has no deadline disposer, and the caller half's own doc says why one is needed. **NOT established as a defect** — the responder may bound the deadline by another route and nobody has looked. That question is the round
- [ ] **[B-75](B-75-the-http1-caller-has-no-active-stream-ceiling.md)** open, cost — the HTTP/1.1 caller has **no `maxActiveStreams` check at all**, zero references, while core bounds `_activeStreams` and http2 bounds `_reservedStreams` and then applies a SECOND ceiling to `_streamParsers`. **Read RPC-05 and C-29 first** — the charge point has been worked over repeatedly and the HTTP/1.1 shape may make the limit meaningless rather than missing
- [ ] **[B-78](B-78-ensuregrpcframe-guesses-whether-data-is-framed.md)** open, cost — `ensureGrpcFrame` decides whether a payload is already framed by PARSING its first five bytes and checking the declared length; a payload that satisfies that is returned unchanged and its first five bytes are then read as a header. A heuristic over application-controlled bytes, failing silently. **Whether the input can be chosen freely is the round** and is cheaper than the fix
- [ ] **[B-79](B-79-bufferedbytes-is-charged-in-core-and-nowhere-in-http2.md)** open, cost — core meters `bufferedBytes` in five places and is explicit that metadata counts toward it; the string does not appear anywhere in `rpc_dart_http2/lib`. The counter-argument has to be MEASURED: a server on `dart:io` has already buffered the peak before this library sees a byte, and if that holds the answer is a doc line. RPC-17 and C-29 first
- [ ] **[B-80](B-80-the-five-byte-prefix-rule-never-reaches-an-http-body.md)** open, cost — the "+5 bytes of prefix" rule is stated twice, both times in core, under a comment explaining that without it the effective limit "becomes `maxMessageLengthBytes - 5`, rejecting a message at exactly the limit". Neither HTTP package references `maxMessageLengthBytes` at all. **First question is which limit an HTTP body is checked against**, if any — the missing +5 is moot otherwise
- [ ] **[B-82](B-82-eleven-case-sensitive-encoding-comparisons.md)** open, cost — the compression registry normalises with `trim().toLowerCase()`; **eleven sites outside it compare a raw header against the lower-case constant**, so `Identity` is a different codec to each. The count is 11, not the ~12 the sweep claimed. Needs a hand-built peer — rpc_dart's own caller always spells it lower-case, so nothing in the suite can reach it. L-10 applies
- [ ] **[B-83](B-83-the-drain-refusal-is-ordered-against-its-siblings-rule.md)** open, cost — the drain refusal tests BEFORE the closed-stream guard; the ceiling refusal sits AFTER it and carries a comment explaining that it must. The drain branch has no comment and gets the opposite order, so it is either an undocumented specialisation or the bug the other comment exists to prevent
- [ ] **[B-85](B-85-a-default-written-twice-and-a-shim-in-two-languages.md)** open, cost — every policy default is written twice, constructor against `fromMap`, literal repeated — and `fromMap` is how a policy crosses an isolate or worker boundary, so the two ends of one process would run on different limits. **The copies AGREE today**; the witness is a test that asserts they do, not a fix. Its native half (the JS shim carried as strings in both Swift and Kotlin) is a separate, device-bound job
- [ ] **[B-84](B-84-three-cleanup-blocks-with-different-subsets.md)** open, cost — three stream-teardown blocks in the http2 caller, each adding something the others do not (`_fcForget`, `_streams.remove`, `_streamSubscriptions.remove`) over a shared core. **The sweep's counts were wrong** — 3 and 4, not 5 and 3. The weakest of the remainder; two measurable questions in the lead, and if both come back clean it closes as a negative in `checked/`
- [ ] **[B-87](B-87-the-sweeps-own-negatives-were-never-verified.md)** open, cost — the sweep's own "already shared" list of nine, **never checked by anyone**. The half where being wrong is most expensive: a false negative here is a divergence nobody looks for again, because it is written down as settled. `drainUntilIdle` is the precedent — the loop was shared and the COUNT feeding it was not, which is how a graceful drain completed instantly with no error. A read, not a bench

## The rest

- [ ] **[B-71](B-71-a-browser-websocket-client-cannot-detect-a-half-open-path.md)** open, risk — a browser WebSocket client has no liveness signal on a half-open path: the API exposes neither the ping interval nor the OUTCOME, so a missing pong never reaches the page and does not close the socket the way `dart:io` does. **Round 442 spent option 1** by repairing the docs, which had asserted the opposite in two places. The three remaining fix shapes are an application-level heartbeat with its own wire cost, and the owner has not asked for one
- [ ] **[B-10](B-10-layers-without-lenses.md)** open, deferred by owner (223, **narrowed** in the backlog review) — three layers of the project have no lens at all. The deferral covers going LOOKING in `data`, `notify` and `blob`; it does NOT cover fixing a defect already measured and written down there, which is what unblocked B-33 and B-46
