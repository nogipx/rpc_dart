---
refines: U-22
paths: [packages/core/rpc_dart/lib/**, packages/transport/*/lib/**]
applies: a doc comment carries the search that produced the code
breaks: "wrong result: the comment is read as current when it records one moment, and the thing a caller needs is buried in it."
applied: [293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 304, 305, 306, 333, 337, 364, 375, 381, 401, 404, 432, 435, 436, 437, 438, 439, 440, 441, 442, 490, 515, 516, 521, 526, 528, 529, 538, 586, 619, 633, 655, 677, 771]
status: confirmed (round 586)
rank: 3
---

# RPC-23 — The narrative beside the code

## Shape

A doc comment that tells the story of how the code came to be: the measurement,
the arms, the wrong turn, the sibling that had it right. Every sentence was true
when written. Together they are unreadable by the person the comment is for, and
unmaintainable by the person who changes the code.

The tell is a comment that answers *how did we find this* rather than *what do I
pass here*. The same shape lives in READMEs, thrown error messages, log levels,
the project's own `CLAUDE.md` rules, and the journal's leads.

## Detector

Per file, **ALL comment lines** — `///` AND `//` — against total lines. Above
~20% the file is prose with code in it. Counting only `///` measures a third of
the problem: the narrative lives in the `//` block inside the method. Core's real
baseline is **6539 comment lines in 23718 (27.6%)**, against the 4430/24049
(18.4%) the `///` metric reported.

> **The density RANKS where to sweep; it does not decide whether to.** Never read
> a sub-threshold number as "this package is clean".

Then, per comment, three questions:

1. **Is there a measured table in it?** A table is a record of one run, on a tree
   that has moved. It belongs in the round record, which is dated and which
   `stale` ages; the comment cannot be aged by anything.
2. **Does it name rounds, commits, siblings or "an earlier version of this
   comment"?** That is journal content addressed to a reader who has the journal.
3. **Could a caller choose a value without it?** Keep exactly what answers that
   plus the one limitation that changes the choice. Everything else goes.

**The unit is a BATCH OF FILES.** Read several files whole, cut every comment in
one pass, one gate, one commit. The ranking gives the order; the three questions
give the rule.

**Sweep explicitly for adjacency**, which no single block shows: a doc fused onto
the wrong declaration (a blank line between doc and declaration hides it; witness
it with an LSP hover before and after); PARAGRAPH fusion (no blank `///` between
two subjects); a block duplicated verbatim, especially around any `typedef`,
re-export or thin wrapper a move left behind; the same measurement in two places.
Look for comment runs that span a blank line, change subject mid-block, or repeat
a phrase already present in the file.

Further cheap queries, each earned by a round below:

- Language, per package: `grep -rlE "[А-Яа-яЁё]" packages/*/*/lib`. Run over
  tracked files, not paths. A hit may be a fixture; some classes only have an
  answer per LINE, not per file.
- Damage from a bulk comment replace, repo-wide:
  `grep -nE '// [A-Za-z][A-Za-z ,.()]*[а-яА-ЯёЁ]'`. A prompt to look, not a check
  that passes.
- The imperative voice in `throw` arguments — "pass", "use", "construct", "call X
  first" — driven literally.
- A comment asserting a REQUIREMENT ("required by", "mandated", "the spec says")
  read against the same file's statement of the format.
- Every "X succeeds" sentence read against the limits on X's path.
- A backlog lead that names a gap, read against the doc for the same symbol.
- A doc that states a COST or safety property, and a README that names a
  component: measure the claim, or ask what the component can do.

## Ask

If this comment were deleted, what would the next caller get wrong?

**On INTERNAL code the reader changes and so does the question.** A private field
has no caller; it has a maintainer about to change it. Ask instead: *what would
someone editing this break without knowing?* The keeper is the INVARIANT — why
the charge point is dispatch and not entry, why the cursor must survive close,
why this counter is per connection — because that is what a plausible edit
destroys silently.

The measurement that PROVED the invariant is still journal. "37 handlers against
a ceiling of 4" belongs in the round; "charged at dispatch, released when the
handler finishes, because a stream can die before its work does" belongs in the
code. The first is evidence, the second is the rule the evidence bought.

Whatever survives is the comment: usually three to six lines, and for a field
usually what it bounds, why the default is what it is, and the one case where
the obvious value is wrong.

**What NOT to cut:** a comment that says what BREAKS if the code is undone — one
or two lines, per `config.md`. `_reject`'s "dart:io tears the connection down
before the status is flushed" is why the drain exists. Cut the how-we-found-it.
Keep the what-breaks-if-you-undo-it.

## Evidence

Headline: `RpcSecurityPolicy` went 236 -> 151 doc lines in round 293; core's
comment baseline was 27.6%, not the 18.4% the `///` count showed. Fused docs:
eight instances by round 305, in five packages, on every kind of declaration.

- **Round 293** — `RpcSecurityPolicy`: four fields carried 127 of 236 doc lines;
  cut to 151 with the tables left in rounds 205, 213-215 and 245. **The comment
  cannot be aged, so it must not carry what ages.**
- **Rounds 294-295** — four comment blocks per round moved 149 lines against a
  baseline of 4430, and the owner stopped it; this is why the unit is a batch.
- **Round 296** — one file per round; the owner stopped that too, for the same
  reason: at 92 files in core alone, one per round does not finish either. Found
  the first fusion: `_validateInbound`'s doc on `_maxPolicyViolations`.
- **Round 297** — measured the `//` gap: `channel_transport.dart` 564 comment
  lines in 1338 (42%) and `transport.dart` 236 in 533 (44%) after being "done".
  Fusion at `_reclaimGrace` wearing `_onDeadlineExceeded`'s doc; eight lines
  duplicated verbatim in `getMessagesForStream`; the 789 MiB budget and
  `openStreams: 30` each written twice.
- **Round 298** — `_normalize` carried `register`'s entire doc, sample included,
  repeated twenty lines later on `register`.
- **Round 299** — a fused doc can HIDE a fact: `_uniqueToken` had no doc, and
  `Random.secure()` throwing on node (non-cryptographic ids) sat under
  `_strongRng`.
- **Round 300** — first package outside core, on a PUBLIC class:
  `RpcWebSocketChannel`'s doc and sample fused onto
  `grpcStatusFromWebSocketCloseCode`.
- **Round 301** — the cost: LSP hover for `_readBounded` returned signature only
  before the fix. A fused doc is INVISIBLE to every tool that reads docs by
  symbol. Also three PARAGRAPH fusions in one package (`stop()` /
  `[drainTimeout]`, a TLS warning / `[policy]`, `_reject`'s CORS / body drain).
- **Round 302** — `rpc_dart_isolate` at **18.2%**, under threshold, held the worst
  fusion of the series (a `//` block describing code 76 lines below). And
  `isolate_transport_stub.dart` named web as its example while the conditional
  export routes `dart.library.js_interop` elsewhere. **Fixing wrong prose COSTS
  lines** (5 -> 9 while the package fell 221 -> 192), and that is correct.
- **Round 303** — the sweep is the only pass that READS every comment: a fusion,
  `"Gárrantees"` in a public doc, and `rpc_http2_server.dart` written in Russian;
  22 more files filed as B-30.
- **Round 304** — the CAUSE of a duplicate: `RpcHttp2OutgoingPump` moved to
  `rpc_http2_common.dart` and `typedef _OutgoingPump` kept a 29-line copy. Sweep
  around anything a move leaves behind.
- **Round 305** — a static function's doc eaten by a `const` 67 lines above.
  **A CLASS doc is the easiest to lose this way**, and it is the doc a user reads
  first.
- **Round 333** — `LogScope.noop` said "zero cost"; the call still builds the
  String: 35 discarded messages, 1566 characters, ~2.0 us VM / ~3.5 us dart2js
  per unary round trip, `isInternal` used at 25 of 58 sites. **A doc comment that
  states a COST is load-bearing; measure it or delete the claim.**
- **Round 364** — `rpc_dart_wasm`'s README named JavaScriptCore, which has no
  WebAssembly. **Some stale prose is IMPOSSIBLE**, refutable from the component's
  own capabilities; **write the reason next to the correction or it comes back**;
  **a claim written INTO prose must be verified before it ships** (`96 MiB sent ->
  1 chunk -> 96 MiB`; `p50 12.9 ms` per frame).
  `../probes/P-55-what-a-wasm-call-costs.md`,
  `../rounds/364-the-readme-named-an-engine-that-cannot-run-it.md`
- **Round 401** — `RpcWebSocketServer.start()`'s error prescribed "construct a new
  `RpcWebSocketServer`", which throws the same error. **A message that tells the
  user what to do is a promise the compiler cannot check, read at the worst
  possible moment.** `../rounds/401-the-remedy-that-was-not-one.md`, RPC-21's
  `../probes/P-87-restart-the-way-the-error-says.md`
- **Round 404** — 228 `throw` sites, ~20 prescribe; the three riskiest were
  correct. **The tell is a message that prescribes rebuilding A when the state
  that blocks you is held by B**; and split a sentence with an `and` in it.
  `../probes/P-89-drive-what-the-message-prescribes.md`,
  `../rounds/404-what-the-messages-promise.md`
- **Round 435** — three of eight transport test files keep Cyrillic as fixtures;
  `stream_distributor.dart` holds **39 runtime log messages**; emoji are 154 lines,
  none in `lib/`. **A detector for a prose defect returns prose AND data**; **two
  style rules in one sentence are two populations.**
  `../rounds/435-the-half-that-ships.md`,
  `../backlog/B-30-russian-comments-outside-the-mandate.md`
- **Round 436** — ten of twelve fixtures in C-47 are round-trips that PASS when
  translated. **Before sweeping, ask which hits would fail if you were WRONG**;
  **a `grep -rl` detector answers "which files", and some classes only have an
  answer at "which lines".**
  `../rounds/436-the-detector-that-cannot-see-its-own-class.md`,
  `../checked/C-47-the-non-ascii-that-must-stay.md`
- **Round 437** — `// < 3ms` on `lessThan(10000)` (10 ms). **A comment in a
  language the reviewers do not read is exempt from review.** And `${minTime}μs`
  is refused by `unnecessary_brace_in_string_interps`: **"unnecessary" in a lint
  means unnecessary TO THE PARSER**; comment the site; the config is the owner's
  to change, not a round's.
  `../rounds/437-the-lint-that-mandates-the-ambiguous-form.md`
- **Round 438** — "100мс" on `milliseconds: 1`, right when written and drifted.
  **Comments in an unread language go un-maintained**; check numbers as you
  translate. `../rounds/438-the-comment-that-was-right-once.md`
- **Round 439** — a bulk replace of `// Регистрируем сервис` half-translated six
  longer comments. **Bulk-replacing comment text is a substring operation on the
  one part of a file nothing validates**; anchor to end of line or edit singly.
  `../rounds/439-the-replace-that-matched-a-prefix.md`
- **Round 440** — the damage grep found no damage repo-wide, bounding 439 at six;
  `replace_all` used eight times, two rejected as prefixes. **When a sweep can
  damage what it edits, write the detector for the DAMAGE.**
  `../rounds/440-the-rule-applied-to-itself.md`
- **Round 441** — "443 lines across 21 files" was repo-wide; `rpc_notify` 230
  lines never in scope, while the rounds swept what the owner's decision names.
  **Report the remainder on the axis of the DECISION.** The damage grep had 4
  false positives in 230 lines.
  `../rounds/441-core-tests-are-down-to-their-fixtures.md`
- **Round 442** — the websocket doc said "A web client is not unprotected" while
  B-71 measured no liveness signal at all. **The dangerous prose is the one that
  tells a reader they are SAFE**; the fix a doc can deliver is honesty, not
  coverage. `../rounds/442-the-doc-that-said-the-opposite.md`
- **Round 490** — `RpcHttpCallerTransport`'s candid "silently degrade" missed that
  a finite stream past either ceiling fails status 8. **Candour about one failure
  reads as a complete account of the failures**; read a LIMIT against the prose
  that promises past it, one arm per limit. `maxBufferedBytes` bounded nothing.
  `../probes/P-129-which-ceiling-stops-a-finite-http1-stream.md`,
  `../rounds/490-the-knob-that-names-the-thing-bounded-nothing.md`, B-99
- **Round 515** — `CLAUDE.md`'s "a bool read" was 235 ns vs 1.8 ns (round 512,
  B-121), and "count calls into a `LogScope` subclass" fails wherever
  `LogScope.child()` derives a scope; override `LogController.add` instead. **A
  convention repeated at hundreds of sites is worth measuring once.** The warning
  rig produced ZERO warnings, so the lead stayed UNVERIFIED: **with no witness
  there is nothing to switch off.**
  `../rounds/515-the-rig-never-reached-the-warning.md`, B-124, B-121
- **Round 516** — NOT_FOUND logged at `error` (`caller 2, responder 1`). **Treat a
  log LEVEL as a claim checked against the project's own vocabulary**;
  `RpcStatus.isFault` is narrower than round 501's `_isServerHealthFailure` ON
  PURPOSE; for a silencing fix the controls run the other way (INTERNAL and a
  status-less `StateError`). `../probes/P-153-what-an-application-status-logs.md`,
  `../rounds/516-an-answer-that-read-as-an-incident.md`, B-124
- **Round 521** — B-129 called eighteen items "small", four were defects (a DoS
  surface among them). **Read the items, not the summary, and split when the
  summary is wrong**; the journal is not exempt.
  `../probes/P-158-does-a-cancel-cut-the-retry-backoff.md`,
  `../rounds/521-a-cleanup-list-with-defects-in-it.md`, B-129
- **Round 586** — `:109` said all headers are HTTP headers, `:461` sent `te:
  trailers` as "required by gRPC-over-HTTP/1.1": `headers delivered 10 -> 9`.
  **A file's own doc comment is a cheaper oracle than any external document**;
  **measure where the thing STOPS** — `_createContextFromMessage` filters `te` and
  must stay for `rpc_dart_http2`. `../probes/P-206-what-te-trailers-reaches.md`,
  `../rounds/586-the-header-core-had-to-filter.md`, B-149
