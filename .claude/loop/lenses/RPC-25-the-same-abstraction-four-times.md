---
refines: U-24
paths: [packages/transport/*/lib/**, packages/core/rpc_dart/lib/src/core/**]
applies: sibling implementations of one interface each hand-roll the same helper
breaks: "wrong result: the copies drift, and the one that drifted is the one nobody compared."
applied: [308, 309, 310, 311, 312, 313, 315, 316, 317, 318, 331, 332, 336, 354, 360, 367, 368, 369, 370, 371, 374, 384, 386, 388, 389, 390, 391, 393, 402, 403, 406, 407, 410, 412, 415, 416, 417, 420, 422, 423, 424, 425, 426, 444, 446, 447, 448, 449, 451, 452, 453, 454, 455, 456, 458, 459, 460, 461, 462, 464, 465, 468, 478, 496, 498, 582, 583, 585, 587, 603, 605, 606, 609, 614, 631, 632, 637, 641, 642, 649, 650, 652, 654, 658, 666, 679, 680, 681, 690, 692, 694, 697, 698, 700, 718, 727, 728]
status: confirmed (round 587)
rank: 7
---

# RPC-25 — The same abstraction, four times

## Shape

Several classes implement the same interface, in different packages, written at
different times. Each needs a helper the interface does not provide, so each
writes one. The copies start identical and then DRIFT, and because no file
imports another, nothing brings the difference to anyone's attention. The defect
is the drift, not the duplication, and it is invisible by construction: a reader
has one copy on screen.

The "copies" need not be classes. Rounds since 334 found them as two branches of
one `if` or one method, an override against its mixin, a constructor against a
method, two `catch` clauses on one `try`, the call sites of one shared helper, a
duplicated VALUE or FACT, and a copy that is simply ABSENT.

## Detector

1. **Find a field every sibling declares.** The name is usually identical,
   because they were copied: `grep -n "_streamControllers" packages/transport/*/lib/**`.
   Point it at FIELDS too: two writers of one field (an initialiser list and a
   method) are two implementations.
2. **Read the METHODS around it in each sibling, side by side**, including what
   each override adds on top of a shared call. Four copies of a five-line method
   are cheap; four copies that disagree are the finding.
3. **Diff them by behaviour, not by text.** What does each copy do that the
   others do not; is that a deliberate specialisation or a slip? Count
   behaviours on the wire, not implementations in files.
4. **Second axis: compare each copy to the thing it READS and to what CONSUMES
   its answer**, not only to its sibling — identical copies can both be wrong.
5. **Enumerate sites by the OPERATION, not the helper's name** (grep what the
   code does), or the site that never had the helper stays invisible. Read an
   existing witness as the list of what a previous sweep covered.
6. Cheap variants: a guarded branch with a long comment (read its sibling
   branches); a `try` with several handlers (state the question each clause
   answers); a doc saying "only through", "the only path", "beyond X's" (a list
   to complete); `ensureX`/`maybeX`/`normalizeX` (does every caller already know?).

"It does not apply here" needs the grep: the lens legitimately does not apply
only after step 1 returns nothing. A lens that needs siblings cannot judge a
single implementation.

## Ask

If these four were one, which copy's behaviour would the shared version have —
and which copies would that CHANGE?

Every copy the answer changes is a drift, and each is either a latent defect or
an undocumented specialisation. There is no third category.

Then, before acting:
- **The bar is the drift, not the line count.** A no-drift candidate earns
  nothing; record each declined candidate with its reason. Exceptions: a
  duplicated RULE (does it decide something, and would enforcing it on three of
  four paths compile?), and unequal coverage, where one copy is at ZERO tests.
- **A divergence is a lead about where to look, never a finding about what
  happens.** Drift is a defect where something reaches it. Before filing an
  absence: is the duty here, is it in a layer this sibling shares, can the
  situation it guards ARISE here at all?
- **A drift is testable by definition**; a round that cannot pin it has a claim.
  "This cannot be tested" needs an API check.
- **Before merging look-alikes, ask how long each result LIVES.** Do not merge
  real specialisations (http2's `_fcMetered`; the http caller's
  `_closedDuringCall()`, hence `closeAll` taking `Object? Function(int)`): one
  class with four flags is worse than four honest copies. Aligning the copies is
  a legitimate alternative to extraction; so is picking an owner.
- **Put the shared version beside the siblings' existing shared dependency**
  (`rpc_dart`'s `src/core/`, next to `BufferedBroadcastController` and
  `RpcMessageParser`), never a new utils package. A shared helper is a new public
  promise (RPC-24), so it is chosen, not emitted. Extraction moves the code but
  not the tests: ask what exercises the NEW unit.

## Evidence

Confirmed in round 587; applied in the rounds listed in the frontmatter. The
headline: round 308's extraction of four per-stream routers (121 lines into a
57-line `RpcStreamRouter`, -64 net) surfaced an unmetered repeat path in
`rpc_http2_caller_transport.getMessagesForStream` that no test or analyzer could
see.

- **Round 307** — `src/`-importing reaches a public symbol in an internal file and does nothing for an underscore; per-LIBRARY privacy is what limits a witness.
- **Round 308** — the four http/http2 routers carried `Map<int, StreamController<...>>`, `getMessagesForStream`, `_emit`, `_emitError`; the http2 caller's repeat call skipped `_fcMetered`, so `_fcOutstanding` only climbed. Nothing could have caught it: it is visible only when the copies are side by side. `RpcStreamRouter` owns the per-stream half only.
- **Round 309** — three server drain loops agreed on logic and drifted on LOGGING (info/debug/none on start; only http2 logged "Drain complete"). Look at what the copies SAY, not only what they compute. `_notify` (eight identical lines) declined: no drift. Isolate was wrongly ruled out by reasoning.
- **Round 310** — `rpc_dart_isolate`'s two variants declared `_incomingCtl`, `_messageSub`, `_closed`, `_onClose` identically, with a byte-identical `close()`; web `send()` closed the channel on failure and did not filter stream 0. Different mechanism is not different abstraction; fixed by aligning, not extracting (browser witness filed as B-31).
- **Round 311** — `_fcWindow` byte-identical in both http2 transports, both with a `??` clause that can never evaluate because `RpcSecurityPolicy`'s const default is non-null (invisible to `dead_null_aware_expression`). Identical copies can BOTH be wrong. `RpcMessageParser(...)` construction declined.
- **Round 312** — wrote 308's witness; a `'z' * 256 KiB` payload deflated ~900:1 (6060 bytes in 22 frames) and passed on broken code. Use incompressible data and assert the threshold was crossed; `grpc-status 0` with no data is not a passing call.
- **Round 313** — two of 312's three "untestable" fixes were testable (`LogController.stream` is public; an extracted function has a contract). Untestability asserted from the shape of a fix is wrong; check what the APIs expose.
- **Round 315** — `_rejectDuplicate` called from eight places in `RpcResponderContract`; merged with no drift because a duplicated RULE is eight chances to answer differently later.
- **Rounds 316, 317, 318** — declined on "no drift, no rule". 317: `RpcResponderContract` and `RpcCallerContract` share a preamble but resolve per REGISTRATION vs per CALL; same computation over different lifetimes is a coincidence (`_RpcCodecMode` was already the shared part).
- **Round 331** — `caller_pipeline.dart`'s two identical stream bridges: ablating `if (!finished)` was caught in serverStream (+1434 ~1 -1) and by NOTHING in bidirectionalStream. Ask which copy the TESTS reach, not only whether the copies agree.
- **Round 332** — `RpcStreamRouter` had no test file 24 rounds after extraction; ablating `operator []` same-stream reuse left http (+123) and http2 (+204) green (L-04 case 1). Extracting shared code moves the code but not the tests; fixed with `test/core/stream_router_test.dart`.
- **Rounds 334, 336** — siblings can be two branches of one `if`: the serialized `UnaryResponder` sent NO status on a request-stream error while `ServerStreamResponder` sent 13, under a comment claiming "the three streaming shapes already route". A comment saying "the others already do this" is a checklist; every shape it does not name is unchecked.
- **Round 354** — `RpcPeerEndpoint.collectEndpointMetrics` lacked `activeResponders`, so `RpcWebSocketServer._inFlightCalls()` drained in 1ms instead of 1746ms (status 14). `null`, not `0`, and `?? 0` erased the difference; the sibling comparison can be an override against its mixin. Getter half is B-37. `../probes/P-46-drain-in-peer-mode.md`, `../rounds/354-the-drain-that-polled-a-key-nobody-published.md`, `../backlog/B-37-endpoints-getter-excludes-peers.md`
- **Round 360** — `RpcStreamIdManager`'s `resumeAfter:` constructor took 4 raw (ids 6, 8, 10 for a client) while the method rounded parity up (7, 9, 11). Two ways to set a field are two implementations, and an initialiser list hides the drift. `_methodPathFromKey` vs `_parseMethodPath` drift declined as B-40: drift is a defect only where something reaches it. `../probes/P-51-three-core-diagnostics.md`, `../rounds/360-two-routes-into-one-concept.md`, `../backlog/B-40-method-path-from-key-drops-dots.md`
- **Round 367** — three flow-control copies, ablations caught 6/1/1 tests: unequal in degree, not kind, so no merge. "Unequally covered" means one copy at ZERO; the `close()` drift on `_fcDeferred`/`_fcOutstanding` declined on 360's rule; `RpcFlowController` has one copy, so no sibling to judge. `../checked/C-39-the-flow-control-copies-are-all-watched.md`
- **Rounds 384, 386, 388, 389, 390, 391** — each found a duty one copy had forgotten; 388 widened where a sibling may live into the dependency; 391 asked to stop applying the lens one copy per round.
- **Round 415** — five duties swept at once, each answered by a sibling; `ping.dart` did not call the shared factory at all, and cancelling the token in `closeResponderResources` made a latent `RpcCallScope.close()` race live. A sweep costs what the LAST copy costs, and unifying a duty can make a dormant defect live. `../rounds/415-five-duties-and-the-sibling-that-answered-each.md`
- **Round 416** — 80 throw sites across 17 packages agreed on `StateError`, which `wireStatusFor` turned into INTERNAL; `_isTransportClosed` matched message text (`channel_transport.dart:437`). Ask what consumes the answer; a consumer matching on a MESSAGE is a missing type (now `RpcClosedException`). `../rounds/416-every-error-names-its-status.md`
- **Rounds 424, 425** — B-56's nine-site table conflated six bridges and four pumps and missed `_pumpBidirectionalResponses`; `RpcCallScope.track` and the circuit breaker's `_wrapStream` HUNG on consumer cancel (control 6ms). Re-derive the table before extracting, and count the PATHS into a mechanism, not the sites; one `StreamBridge.onCancel` ablation now reddens both witnesses. `../rounds/425-the-cancel-path-the-table-had-no-column-for.md`, `../probes/P-95-bridge-cancel-paths.md`
- **Round 426** — round 390's caller fix had a responder mirror: `responseSink` kept draining at +32/+35 messages per quarter-second (+1 control) despite `BidirectionalStreamResponder.done`. A fix on one twin is a question about the other; the worse copy was the quieter one; B-56 contradicted itself. One `SinkPump` ablation reddens 390's witness too. `../rounds/426-the-mirror-nobody-held-up.md`, `../probes/P-96-response-pump-outlives-its-call.md`
- **Round 444** — `ping()` merged context headers with a bare `addAll` where two sites filtered `isReserved`. A missing copy cannot be found by comparing the copies you have; read `cancellation_header_reserved_test.dart` as the list of what was swept (L-12). `../rounds/444-the-third-merge-site-nobody-swept.md`, `../probes/P-98-the-same-context-down-two-call-shapes.md`
- **Round 446** — `RpcContext` held `128 / 128 / 8 KiB / 64 KiB` equal to `RpcSecurityPolicy`'s defaults but unreachable: `maxHeaders` 512 with 200 headers SUCCEEDED with 73 missing. A duplicated value with an unreachable second home makes its knob MONOTONE; raise each limit and measure. Read the decision commit (`f876d602`) before rewriting a test. `../rounds/446-the-knob-that-only-turned-down.md`, `../probes/P-100-does-raising-maxheaders-raise-anything.md`
- **Round 447** — the DATA branch of `_onMessage` checked `_statusReceived` before END_STREAM (status 14) and the HEADERS branch did not (clean end after 2 items). Find the guarded branch with the long comment and read its neighbours. `../rounds/447-the-same-loss-on-the-other-frame.md`, `../probes/P-101-an-ending-with-no-status-per-frame-type.md`
- **Round 448** — `_notifyPeerOfCancellation` was shared; unary `await`ed it and never settled on a send that never completes, streaming used `unawaited`. Extraction moves the divergence to the call sites; a catch does not catch a hang. `../rounds/448-the-promise-that-was-too-big.md`, `../probes/P-102-cancel-against-a-send-that-never-completes.md`
- **Round 449** — three reconnect machines diverged but none dropped a send; the surviving divergence was what they TOLD the caller (UNAVAILABLE vs FAILED_PRECONDITION). Right about the divergence, wrong about the harm. `../rounds/449-the-window-was-real-the-loss-was-not.md`, `../checked/C-48-no-machine-drops-a-send-during-its-factory-await.md`
- **Round 451** — `StreamProcessor` lacked `_setupDeadlineMonitoring` because `responder_pipeline` owns the deadline one layer up. Before filing an absence, ask which layer OWNS the resources the duty needs. `../rounds/451-the-disposer-was-in-the-other-layer.md`, `../checked/C-50-the-responder-bounds-its-deadline-in-the-pipeline.md`
- **Round 452** — B-84's table listed `_fcForget` but not `_outgoingPumps.remove(...).dispose()`, which `resetStream` leaked (pumps 1 -> 1), sitting 26 rounds in B-70. Re-derive the sweep's cells; a divergence you cannot observe is an unbuilt instrument (three counts in `health()`). `../rounds/452-the-weakest-lead-had-a-leak-in-it.md`, `../probes/P-105-what-each-teardown-block-clears.md`
- **Round 454** — a late frame on a closed id got status 14 while draining and nothing otherwise; the commented copy was right (U-01's other half). A rule written on one copy is a specification for its siblings; count answers, since `[14]` and `[14, 14]` both pass `contains` (B-90). `../rounds/454-the-order-the-sibling-wrote-down.md`, `../probes/P-106-what-a-late-frame-on-a-closed-stream-is-told.md`
- **Rounds 455, 457** — `ensureGrpcFrame` re-derived from bytes a fact both callers knew; a 13-byte body starting 0x99 became 18 bytes. The callee's NAME is the detector; look for a constant before building B-62's channel. 455 fixed it in the wrong layer and 457 reverted it. `../rounds/455-the-guess-over-bytes-the-peer-chose.md`, `../probes/P-107-does-a-body-that-looks-framed-survive-unchanged.md`
- **Round 456** — `isSupported('Identity')` normalised, the `!= 'identity'` check did not, `compress` normalised: the compressed flag on uncompressed bytes. When copies differ in STRICTNESS, the lenient one hides the strict one; put the witness where the copies are independent, and check a lead's reachability claim (B-82 was wrong). `../rounds/456-the-registry-was-lenient-and-nothing-else-was.md`, `../probes/P-108-what-the-case-of-grpc-encoding-changes.md`
- **Round 458** — `maxMessageLengthBytes` compared against an HTTP FRAME refused a message exactly at the limit (status 8) where channel accepted; difference 5 bytes. Check a limit's UNIT across layers; bound on wire size, report the configured one; set the limit to the message's own length. `../rounds/458-a-message-at-exactly-the-limit.md`, `../probes/P-109-a-message-at-exactly-the-limit.md`
- **Round 459** — http2's "missing" buffered-bytes charge lives in core's `responder_pipeline`, and the window cannot open on HTTP/2. Ask whether the situation can ARISE; a grep for a NAME (B-79's `bufferedBytes`) is not evidence about a MECHANISM. `../rounds/459-the-charge-lives-where-they-meet.md`, `../checked/C-51-http2-does-charge-the-buffered-bytes.md`
- **Round 460** — B-86 generalised from empty terminal metadata; http2 emits TWO terminal messages and HTTP/1.1 one. A shared shape licenses a hypothesis about the sibling, never a conclusion. `../rounds/460-one-terminal-message-not-two.md`, `../checked/C-52-http1-tells-the-consumer-when-a-status-never-came.md`
- **Round 461** — the fix moved into the producer: `RpcMessageParser` takes `emitFramed`, tracks `alreadyFramed`, `frameParsedMessage` deleted (455's version broke gzip, status 13). Ask first whether the PRODUCER knows; one canary (`emitFramed: false`) reddening P-107's and P-108's witnesses proves the boundary, and a fix where the fact is unavailable cannot be tested. `../rounds/461-the-parser-answers-so-nobody-guesses.md`
- **Round 462** — B-77's three implementations were two behaviours (http2 inherits core's content-type check), and a fourth site existed on the caller side: the HTTP/1.1 caller had none. A count of implementations is not a count of behaviours; enumerate both directions of a duty. The owner's decision here was "the three collapse to one function, and http2 starts calling it", and on a surface of two that instruction makes a live check looser. `../rounds/462-three-implementations-two-behaviours.md`, `../probes/P-111-content-type-across-the-layers.md`
- **Round 464** — websocket/http2/health answered the disconnected state 9/14/degraded during the await and 9/9/unhealthy after failure; unified as `RpcNoConnectionException(what, reconnecting:)`. When the Ask has no winner, the copies answer two questions; take the flag from what each copy already keeps (single-flight `Future`s, a `Completer`), not a fresh `bool _reconnecting`. `../rounds/464-two-states-wearing-one-word.md`, `../probes/P-113-what-one-state-tells-a-caller.md`
- **Round 465** — three id-reuse mechanisms, one correct outcome; no merge. An ablation aimed at one copy (`_nextStreamId = 1` in http2) tests every copy built on it: the proxy's `_idWatermark` stayed clean. `../rounds/465-three-mechanisms-one-outcome.md`, `../probes/P-115-does-an-id-come-back-after-a-reconnect.md`, `../checked/C-53-three-id-mechanisms-one-correct-outcome.md`
- **Round 468** — B-89's third parity "copy", `RpcHttp2ResponderTransport`'s `_nextStreamId = 2`, has no `IRpcStreamIdSequence` entry point. A field is a copy of a RULE only if something can drive it; a clean arm under ablation is a finding too. `../rounds/468-the-third-home-has-no-door.md`, `../probes/P-117-where-the-parity-rules-meet.md`, `../checked/C-54-the-parity-rules-never-meet.md`
- **Rounds 471, 478** — B-33's conditional-delete matrix, partly taken from prose in 471, was already half-unified by 416; missing blob with `expectedVersion` was ABORTED in `in_memory`/`sqlite`, `false` in `webdav`/`minio`. Re-read the copies; between two defensible unifications prefer the one that cannot break a working caller (`false`); a unified answer can cost one adapter a query (`sqlite`'s `changes() == 0`). `../rounds/478-one-contract-for-a-conditional-delete.md`
- **Round 496** — `RpcMessageParser` reallocated per chunk (16 MiB: 1515 ms -> 8 ms) while `RpcFrameMultiplexedChannel` was amortized. The divergence can be PERFORMANCE with both copies correct; take the sibling's invariants too (size check BEFORE the append). B-105. `../probes/P-134-what-reassembling-one-large-message-costs.md`, `../rounds/496-the-sibling-had-solved-it-one-layer-up.md`
- **Round 498** — `BaseProcessor.notifyPeerOfAbort`'s doc ("reachable only through a cancellation token") named one ending; TIMEOUT in `UnaryCaller`/`ClientStreamCaller` sent no notice (cancelled=0 -> 1; 500 ms deadline control already 1). "Only through" is a list with one entry; the second witness's canary passed, so check each ablation kills each witness. B-107. `../probes/P-136-what-bounds-a-call-with-no-deadline.md`, `../rounds/498-giving-up-without-telling-anyone.md`
- **Round 582** — HTTP/1.1 sent two `content-type` values (`_completeResponse` and `RpcMetadata.forServerInitialResponse()`), exposed by round 545's header MERGE. Ask which keys have two writers; the remedy was picking an owner (the transport), not a shared helper (RPC-08). B-146. `../probes/P-202-which-content-type-a-grpc-over-http1-response-carries.md`, `../rounds/582-two-answers-to-one-question.md`
- **Round 583** — `grpcStatusFromHttpStatus` lacked 405, 408, 415; only 408 needed a row (14, attempts 3). An exception clause is a list to complete, decided by one property (retryability); a copy disagreeing with its source is not automatically a defect. B-147, B-222. `../probes/P-203-what-each-http1-rejection-becomes-at-the-caller.md`, `../rounds/583-the-row-the-table-was-missing.md`
- **Round 585** — the caller's body buffer was a `List<int>` where the responder used `BytesBuilder(copy: false)`: 32 MiB payload +205 MiB -> +0. Bracket a cost outside the library (the bare `LIST` arm varied +165 to +528 MiB), and pin a performance fix by its deterministic consequence (`identical(sent, payload)`). B-148. `../probes/P-205-what-one-buffered-request-body-costs.md`, `../rounds/585-the-buffer-the-sibling-had-already-replaced.md`
- **Round 587** — a generic `catch` logged at `error` where `http.RequestAbortedException` above it used `internal`: 8 in-flight calls gave 8 errors on `close()` (8/1/0 scaling). Two `catch` clauses on one `try` are two copies of a decision; when a claim says "each", the arm must scale; a moved log needs an instrument that admits the lower level. B-143. `../probes/P-207-what-an-orderly-close-logs-per-in-flight-call.md`, `../rounds/587-eight-calls-eight-errors.md`
