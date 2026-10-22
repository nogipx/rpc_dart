---
refines: U-14
paths: [packages/transport/*/lib/**, packages/core/rpc_dart/lib/src/core/**]
applies: sibling implementations of one interface each hand-roll the same helper
breaks: "wrong result: the copies drift, and the one that drifted is the one nobody compared."
applied: [308, 309, 310, 311, 312, 313, 315, 316, 317, 318, 331, 332, 336, 354, 360, 367, 368, 369, 370, 371, 374, 384, 386, 388, 389, 390, 391, 393, 402, 403, 406, 407, 410, 412, 415, 416, 417, 420, 422, 423, 424, 425, 426, 444, 446, 447, 448, 449, 451, 452, 453, 454, 455, 456, 458, 459, 460, 461, 462, 464, 465, 468, 478, 496, 498, 582, 583, 585, 587, 603, 605, 606, 609, 614, 631, 632, 637, 641, 642, 649, 650, 652, 654, 658, 666, 679, 680, 681, 690, 692, 694, 697, 698, 700, 718, 727, 728, 791, 796, 814, 829, 835, 846, 847, 848, 851, 853, 854, 855, 857, 858, 861, 862, 863, 864, 865, 866, 867, 876, 877, 878, 879, 895, 897, 898, 899]
status: confirmed (round 846)
rank: 4
---

# RPC-25 — The same abstraction, four times

## Shape

Several classes implement one interface, in different packages, written at
different times. Each needs a helper the interface lacks, so each writes one.
The copies start identical and then DRIFT. No file imports another, so nothing
shows the difference. The defect is the drift, not the duplication, and a
reader sees one copy at a time.

Copies need not be classes. Since round 334 they were found as two branches of
one `if` or one method, an override against its mixin, a constructor against a
method, two `catch` clauses on one `try`, the call sites of one shared helper, a
duplicated VALUE or FACT, and a copy that is simply ABSENT.

## Detector

1. **Find a field every sibling declares.** The name is usually identical,
   because it was copied: `grep -n "_streamControllers" packages/transport/*/lib/**`.
   Point it at FIELDS too: two writers of one field (an initialiser list and a
   method) are two implementations.
2. **Read the METHODS around it in each sibling, side by side**, including what
   each override adds on top of a shared call. Copies that disagree are the
   finding.
3. **Diff by behaviour, not by text.** What does each copy do that the others do
   not; is it a deliberate specialisation or a slip? Count behaviours on the
   wire, not implementations in files.
4. **Compare each copy to what it READS and to what CONSUMES its answer**, not
   only to its sibling: identical copies can both be wrong.
5. **Enumerate sites by the OPERATION, not the helper's name**, or the site that
   never had the helper stays invisible. Read an existing witness as the list of
   what a previous sweep covered.
6. Cheap variants: a guarded branch with a long comment (read its sibling
   branches); a `try` with several handlers (state the question each clause
   answers); a doc saying "only through", "the only path", "beyond X's" (a list
   to complete); `ensureX`/`maybeX`/`normalizeX` (does every caller already know?).

"It does not apply here" needs the grep: only after step 1 returns nothing. A
lens that needs siblings cannot judge a single implementation.

## Ask

If these four were one, which copy's behaviour would the shared version have,
and which copies would that CHANGE?

Every copy the answer changes is a drift: a latent defect or an undocumented
specialisation. There is no third category.

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
  class with four flags is worse than four honest copies. Aligning the copies,
  or picking an owner, is a legitimate alternative to extraction.
- **Put the shared version beside the siblings' existing shared dependency**
  (`rpc_dart`'s `src/core/`, next to `BufferedBroadcastController` and
  `RpcMessageParser`), never a new utils package. A shared helper is a new
  public promise (RPC-24), so it is chosen, not emitted. Extraction moves the
  code but not the tests: ask what exercises the NEW unit.

## Evidence

- **307** — per-LIBRARY privacy limits a witness: `src/` imports reach public symbols, not underscores.
- **308** — merging four routers (121 lines into a 57-line `RpcStreamRouter`, -64 net) showed the http2 caller's repeat `getMessagesForStream` skipped `_fcMetered`. Visible only side by side.
- **309** — three drain loops drifted on LOGGING. Compare what copies SAY.
- **310** — web isolate `send()` closed the channel on failure, did not filter stream 0. Fixed by aligning (B-31).
- **311** — `_fcWindow` identical in both http2 transports, both with a dead `??`. Identical copies can BOTH be wrong.
- **312** — 308's witness passed on broken code with a ~900:1 payload. Use incompressible data.
- **313** — two of 312's three "untestable" fixes were testable. Check the APIs.
- **315** — `_rejectDuplicate` (eight sites) merged with no drift: a duplicated RULE.
- **316, 317, 318** — declined: no drift, no rule; per REGISTRATION vs per CALL is coincidence.
- **331** — an `if (!finished)` ablation was caught in serverStream, not bidirectionalStream. Ask which copy the TESTS reach.
- **332** — `RpcStreamRouter` had no tests (L-04 case 1); added `test/core/stream_router_test.dart`.
- **334, 336** — `UnaryResponder` sent NO status where `ServerStreamResponder` sent 13. "The others already do this" is a checklist.
- **354** — `collectEndpointMetrics` lacked `activeResponders`: drain 1ms, not 1746ms. Override vs mixin is a pair. B-37. `../probes/P-46-drain-in-peer-mode.md`, `../rounds/354-the-drain-that-polled-a-key-nobody-published.md`, `../backlog/B-37-endpoints-getter-excludes-peers.md`
- **360** — `resumeAfter:` constructor vs method disagreed on parity: two writers, two implementations. B-40 declined: unreached. `../probes/P-51-three-core-diagnostics.md`, `../rounds/360-two-routes-into-one-concept.md`, `../backlog/B-40-method-path-from-key-drops-dots.md`
- **367** — flow-control ablations caught 6/1/1: no merge; "unequal" means ZERO. `../checked/C-39-the-flow-control-copies-are-all-watched.md`
- **384, 386, 388, 389, 390, 391** — each found a duty one copy forgot; 391: stop one copy per round.
- **415** — five duties swept; unifying one made a dormant `RpcCallScope.close()` race live. `../rounds/415-five-duties-and-the-sibling-that-answered-each.md`
- **416** — 80 `StateError` sites became INTERNAL. A consumer matching a MESSAGE is a missing type (`RpcClosedException`). `../rounds/416-every-error-names-its-status.md`
- **424, 425** — B-56's table missed a pump; two wrappers HUNG on cancel. Count PATHS, not sites. `../rounds/425-the-cancel-path-the-table-had-no-column-for.md`, `../probes/P-95-bridge-cancel-paths.md`
- **426** — 390's caller fix had a responder mirror (+32/+35 vs +1). A fix on one twin is a question about the other. `../rounds/426-the-mirror-nobody-held-up.md`, `../probes/P-96-response-pump-outlives-its-call.md`
- **444** — `ping()` skipped the `isReserved` filter. Find a missing copy from the witness list (L-12). `../rounds/444-the-third-merge-site-nobody-swept.md`, `../probes/P-98-the-same-context-down-two-call-shapes.md`
- **446** — `maxHeaders` 512 with 200 headers lost 73: a duplicated value makes its knob MONOTONE. Read `f876d602` before rewriting a test. `../rounds/446-the-knob-that-only-turned-down.md`, `../probes/P-100-does-raising-maxheaders-raise-anything.md`
- **447** — DATA checked `_statusReceived`, HEADERS did not. Read the guarded branch's neighbours. `../rounds/447-the-same-loss-on-the-other-frame.md`, `../probes/P-101-an-ending-with-no-status-per-frame-type.md`
- **448** — unary `await`ed a shared notice and hung. Extraction moves drift to call sites. `../rounds/448-the-promise-that-was-too-big.md`, `../probes/P-102-cancel-against-a-send-that-never-completes.md`
- **449** — reconnect machines lost no send; they differed in what they TOLD the caller. `../rounds/449-the-window-was-real-the-loss-was-not.md`, `../checked/C-48-no-machine-drops-a-send-during-its-factory-await.md`
- **451** — a "missing" deadline lived one layer up. Ask which layer OWNS the duty. `../rounds/451-the-disposer-was-in-the-other-layer.md`, `../checked/C-50-the-responder-bounds-its-deadline-in-the-pipeline.md`
- **452** — B-84's table missed a pump leak (1 -> 1), 26 rounds in B-70. Re-derive the cells. `../rounds/452-the-weakest-lead-had-a-leak-in-it.md`, `../probes/P-105-what-each-teardown-block-clears.md`
- **454** — a late frame got 14 only while draining (U-01). A rule on one copy specifies its siblings; count answers (B-90). `../rounds/454-the-order-the-sibling-wrote-down.md`, `../probes/P-106-what-a-late-frame-on-a-closed-stream-is-told.md`
- **455, 457** — `ensureGrpcFrame` guessed a known fact (13 bytes became 18). The NAME is the detector; check before B-62. 457 reverted 455. `../rounds/455-the-guess-over-bytes-the-peer-chose.md`, `../probes/P-107-does-a-body-that-looks-framed-survive-unchanged.md`
- **456** — the lenient copy hid the strict one; B-82's claim was wrong. `../rounds/456-the-registry-was-lenient-and-nothing-else-was.md`, `../probes/P-108-what-the-case-of-grpc-encoding-changes.md`
- **458** — a limit on FRAME size refused an exact-limit message (status 8; 5 bytes). Check a limit's UNIT. `../rounds/458-a-message-at-exactly-the-limit.md`, `../probes/P-109-a-message-at-exactly-the-limit.md`
- **459** — a NAME grep (B-79's `bufferedBytes`) is not evidence about a MECHANISM. `../rounds/459-the-charge-lives-where-they-meet.md`, `../checked/C-51-http2-does-charge-the-buffered-bytes.md`
- **460** — B-86 over-generalised; a shared shape is a hypothesis. `../rounds/460-one-terminal-message-not-two.md`, `../checked/C-52-http1-tells-the-consumer-when-a-status-never-came.md`
- **461** — fixed in the PRODUCER (`emitFramed`); one canary reddened P-107's and P-108's witnesses. `../rounds/461-the-parser-answers-so-nobody-guesses.md`
- **462** — B-77's three implementations were two behaviours. The owner's decision here was "the three collapse to one function, and http2 starts calling it", and on a surface of two that instruction makes a live check looser. `../rounds/462-three-implementations-two-behaviours.md`, `../probes/P-111-content-type-across-the-layers.md`
- **464** — three copies answered 9/14/degraded: two states, one word. Take the flag from state already kept. `../rounds/464-two-states-wearing-one-word.md`, `../probes/P-113-what-one-state-tells-a-caller.md`
- **465** — three id mechanisms, one outcome. Ablating one copy tests all built on it. `../rounds/465-three-mechanisms-one-outcome.md`, `../probes/P-115-does-an-id-come-back-after-a-reconnect.md`, `../checked/C-53-three-id-mechanisms-one-correct-outcome.md`
- **468** — B-89's third copy has no entry point; a field copies a RULE only if driven. `../rounds/468-the-third-home-has-no-door.md`, `../probes/P-117-where-the-parity-rules-meet.md`, `../checked/C-54-the-parity-rules-never-meet.md`
- **471, 478** — B-33: ABORTED vs `false`. Prefer the unification that cannot break a working caller. `../rounds/478-one-contract-for-a-conditional-delete.md`
- **496** — per-chunk reallocation (16 MiB: 1515 ms -> 8 ms): drift can be PERFORMANCE. B-105. `../probes/P-134-what-reassembling-one-large-message-costs.md`, `../rounds/496-the-sibling-had-solved-it-one-layer-up.md`
- **498** — TIMEOUT sent no notice (0 -> 1). "Only through" is a list of one. B-107. `../probes/P-136-what-bounds-a-call-with-no-deadline.md`, `../rounds/498-giving-up-without-telling-anyone.md`
- **582** — two `content-type` writers; pick an owner (RPC-08). B-146. `../probes/P-202-which-content-type-a-grpc-over-http1-response-carries.md`, `../rounds/582-two-answers-to-one-question.md`
- **583** — of 405, 408, 415 only 408 needed a row. An exception clause is a list to complete. B-147, B-222. `../probes/P-203-what-each-http1-rejection-becomes-at-the-caller.md`, `../rounds/583-the-row-the-table-was-missing.md`
- **585** — `List<int>` vs `BytesBuilder(copy: false)`: 32 MiB +205 MiB -> +0. B-148. `../probes/P-205-what-one-buffered-request-body-costs.md`, `../rounds/585-the-buffer-the-sibling-had-already-replaced.md`
- **587** — two `catch` clauses, two log levels: 8 calls, 8 errors on `close()`. B-143. `../probes/P-207-what-an-orderly-close-logs-per-in-flight-call.md`, `../rounds/587-eight-calls-eight-errors.md`
- **846** — `holdsPartialFrame` guarded requests only: a cut response ended clean. **Grep a rule's every use and ask which side each is on.** `../rounds/846-a-response-cut-mid-message-is-an-error.md`, `../probes/P-315-a-response-cut-mid-message.md`
