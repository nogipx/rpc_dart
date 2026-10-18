---
refines: U-22
paths: [packages/core/rpc_dart/lib/**, packages/transport/*/lib/**]
applies: a doc comment carries the search that produced the code
breaks: "wrong result: the comment is read as current when it records one moment, and the thing a caller needs is buried in it."
applied: [293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 304, 305, 306, 333, 337, 364, 375, 381, 401, 404, 432, 435, 436, 437, 438, 439, 440, 441, 442, 490, 515, 516, 521, 526, 528, 529, 538, 586, 619, 633, 655, 677, 771, 824, 834, 883]
status: confirmed (round 883)
rank: 17
---

# RPC-23 — The narrative beside the code

## Shape

A doc comment that tells how the code came to be: the measurement, the arms,
the wrong turn, the sibling that had it right. Each sentence was true when
written; together they are unreadable for the user and unmaintainable for the
editor.

The tell: it answers *how did we find this*, not *what do I pass here*. It also
lives in READMEs, thrown error messages, log levels, the project's own
`CLAUDE.md` rules, and the journal's leads.

## Detector

Per file, **ALL comment lines** — `///` AND `//` — against total lines. Above
~20% the file is prose with code in it. Counting only `///` misses the `//`
narrative inside methods: core's real baseline is **6539 comment lines in 23718
(27.6%)**, against the 4430/24049 (18.4%) the `///` metric reported.

> **The density RANKS where to sweep; it does not decide whether to.** Never read
> a sub-threshold number as "this package is clean".

Then, per comment, three questions:

1. **Is there a measured table in it?** A table records one run on a tree that
   has moved. It belongs in the dated round record, which `stale` ages; nothing
   ages a comment.
2. **Does it name rounds, commits, siblings or "an earlier version of this
   comment"?** That is journal content.
3. **Could a caller choose a value without it?** Keep exactly what answers that
   plus the one limitation that changes the choice. Everything else goes.

**The unit is a BATCH OF FILES.** Read several files whole, cut every comment in
one pass, one gate, one commit. The density sets the order; the three
questions decide what goes.

**Sweep explicitly for adjacency**, which no single block shows: a doc fused onto
the wrong declaration (a blank line between doc and declaration hides it;
witness it with an LSP hover before and after); PARAGRAPH fusion (no blank `///`
between two subjects); a block duplicated verbatim, especially around a
`typedef`, re-export or thin wrapper a move left behind; the same measurement in
two places. Look for comment runs that span a blank line, change subject
mid-block, or repeat a phrase already in the file.

Further cheap queries, each earned by a round below:

- Language, per package: `grep -rlE "[А-Яа-яЁё]" packages/*/*/lib`, over
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
has a maintainer, not a caller. Ask: *what would someone editing this break
without knowing?* Keep the INVARIANT — why the charge point is dispatch and not
entry, why the cursor must survive close, why this counter is per connection —
because a plausible edit destroys it silently.

The measurement that PROVED it is journal: "37 handlers against a ceiling of 4"
goes in the round; "charged at dispatch, released when the handler finishes,
because a stream can die before its work does" goes in the code.

What survives is usually three to six lines; for a field, what it bounds, why
the default is what it is, and the one case where the obvious value is wrong.

**What NOT to cut:** a comment that says what BREAKS if the code is undone — one
or two lines, per `config.md`. `_reject`'s "dart:io tears the connection down
before the status is flushed" is why the drain exists. Cut the how-we-found-it.
Keep the what-breaks-if-you-undo-it.

## Evidence

- **Round 293** — `RpcSecurityPolicy`: four fields held 127 of 236 doc lines; cut to 151, tables left in rounds 205, 213-215, 245. **A comment cannot be aged, so it must not carry what ages.**
- **Rounds 294-295** — four blocks per round moved 149 lines against 4430; the owner stopped it. Hence the batch.
- **Round 296** — one file per round, also stopped: 92 files in core alone. First fusion: `_validateInbound`'s doc on `_maxPolicyViolations`.
- **Round 297** — the `//` gap: `channel_transport.dart` 564 of 1338 (42%), `transport.dart` 236 of 533 (44%) after "done". `_reclaimGrace` wore `_onDeadlineExceeded`'s doc; eight lines duplicated in `getMessagesForStream`; the 789 MiB budget and `openStreams: 30` written twice each.
- **Round 298** — `_normalize` carried `register`'s whole doc and sample, repeated twenty lines later on `register`.
- **Round 299** — a fused doc HID a fact: undocumented `_uniqueToken`'s `Random.secure()` throwing on node (non-cryptographic ids) sat under `_strongRng`.
- **Round 300** — first outside core, a PUBLIC class: `RpcWebSocketChannel`'s doc and sample fused onto `grpcStatusFromWebSocketCloseCode`.
- **Round 301** — hover on `_readBounded` gave only the signature before the fix: **a fused doc is INVISIBLE to tools reading docs by symbol.** Three PARAGRAPH fusions in one package (`stop()` / `[drainTimeout]`, a TLS warning / `[policy]`, `_reject`'s CORS / body drain).
- **Round 302** — `rpc_dart_isolate`, **18.2%** and under threshold, held the worst fusion (a `//` block for code 76 lines below); `isolate_transport_stub.dart` named web, which the conditional export routes elsewhere (`dart.library.js_interop`). **Fixing wrong prose COSTS lines** (5 -> 9 as the package fell 221 -> 192), correctly.
- **Round 303** — only the sweep READS every comment: a fusion, `"Gárrantees"` in a public doc, `rpc_http2_server.dart` in Russian; 22 more files filed as B-30.
- **Round 304** — a duplicate's cause: `RpcHttp2OutgoingPump` moved to `rpc_http2_common.dart`, `typedef _OutgoingPump` kept a 29-line copy. Sweep around what a move leaves.
- **Round 305** — a static function's doc eaten by a `const` 67 lines above; eight fused docs by now, in five packages, on every kind of declaration. **A CLASS doc is the easiest to lose this way**, and the first a user reads.
- **Round 333** — `LogScope.noop` said "zero cost", yet the String is built: 35 discarded messages, 1566 characters, ~2.0 us VM / ~3.5 us dart2js per unary round trip, `isInternal` at 25 of 58 sites. **A stated COST is load-bearing: measure or delete it.**
- **Round 364** — `rpc_dart_wasm`'s README named JavaScriptCore, which has no WebAssembly. **Some stale prose is IMPOSSIBLE given the component's capabilities; put the reason beside the correction or it returns; verify a claim before writing it** (`96 MiB sent -> 1 chunk -> 96 MiB`; `p50 12.9 ms` per frame). `../probes/P-55-what-a-wasm-call-costs.md`, `../rounds/364-the-readme-named-an-engine-that-cannot-run-it.md`
- **Round 401** — `RpcWebSocketServer.start()`'s error said "construct a new `RpcWebSocketServer`", which throws the same error. **A remedy in a message is a promise no compiler checks.** `../rounds/401-the-remedy-that-was-not-one.md`, RPC-21's `../probes/P-87-restart-the-way-the-error-says.md`
- **Round 404** — 228 `throw` sites, ~20 prescribe; the three riskiest were correct. **The tell: a message prescribing a rebuild of A while B holds the blocking state**; split a sentence with an `and`. `../probes/P-89-drive-what-the-message-prescribes.md`, `../rounds/404-what-the-messages-promise.md`
- **Round 435** — three of eight transport test files keep Cyrillic fixtures; `stream_distributor.dart` holds **39 runtime log messages**; emoji 154 lines, none in `lib/`. **A prose detector returns prose AND data; two style rules in one sentence are two populations.** `../rounds/435-the-half-that-ships.md`, `../backlog/B-30-russian-comments-outside-the-mandate.md`
- **Round 436** — ten of twelve fixtures in C-47 are round-trips that PASS translated. **Before sweeping, ask which hits would fail if you were WRONG; `grep -rl` answers "which files", some classes need "which lines".** `../rounds/436-the-detector-that-cannot-see-its-own-class.md`, `../checked/C-47-the-non-ascii-that-must-stay.md`
- **Round 437** — `// < 3ms` on `lessThan(10000)` (10 ms). **An unread language escapes review.** `${minTime}μs` is refused by `unnecessary_brace_in_string_interps`: **"unnecessary" means TO THE PARSER**; comment the site; the config is the owner's. `../rounds/437-the-lint-that-mandates-the-ambiguous-form.md`
- **Round 438** — "100мс" on `milliseconds: 1`, right once, drifted. **Unread-language comments go un-maintained**; check numbers while translating. `../rounds/438-the-comment-that-was-right-once.md`
- **Round 439** — a bulk replace of `// Регистрируем сервис` half-translated six longer comments. **Bulk-replacing comment text is a substring edit nothing validates**; anchor to end of line or edit singly. `../rounds/439-the-replace-that-matched-a-prefix.md`
- **Round 440** — the damage grep found none repo-wide, bounding 439 at six; of eight `replace_all` uses, two rejected as prefixes. **If a sweep can damage what it edits, detect the DAMAGE.** `../rounds/440-the-rule-applied-to-itself.md`
- **Round 441** — "443 lines across 21 files" was repo-wide; `rpc_notify`'s 230 were never in scope. **Report the remainder on the axis of the owner's DECISION.** The damage grep: 4 false positives in 230 lines. `../rounds/441-core-tests-are-down-to-their-fixtures.md`
- **Round 442** — the websocket doc said "A web client is not unprotected"; B-71 measured no liveness signal. **The dangerous prose says you are SAFE**; a doc can deliver honesty, not coverage. `../rounds/442-the-doc-that-said-the-opposite.md`
- **Round 490** — `RpcHttpCallerTransport`'s candid "silently degrade" missed that a finite stream past either ceiling fails status 8; `maxBufferedBytes` bounded nothing. **Candour about one failure reads as the whole account**; read each LIMIT against prose that promises past it. `../probes/P-129-which-ceiling-stops-a-finite-http1-stream.md`, `../rounds/490-the-knob-that-names-the-thing-bounded-nothing.md`, B-99
- **Round 515** — `CLAUDE.md`'s "a bool read" was 235 ns vs 1.8 ns (round 512, B-121); "count calls into a `LogScope` subclass" fails under `LogScope.child()`; override `LogController.add`. **Measure a convention used at hundreds of sites.** ZERO warnings from the rig left the lead UNVERIFIED: **no witness, nothing to switch off.** `../rounds/515-the-rig-never-reached-the-warning.md`, B-124, B-121
- **Round 516** — NOT_FOUND logged at `error` (`caller 2, responder 1`). **Check a log LEVEL against the project's vocabulary**; `RpcStatus.isFault` is narrower than round 501's `_isServerHealthFailure` ON PURPOSE; a silencing fix's controls are INTERNAL and a status-less `StateError`. `../probes/P-153-what-an-application-status-logs.md`, `../rounds/516-an-answer-that-read-as-an-incident.md`, B-124
- **Round 521** — B-129's eighteen "small" items held four defects, a DoS surface among them. **Read the items, not the summary; split when it is wrong** — the journal too. `../probes/P-158-does-a-cancel-cut-the-retry-backoff.md`, `../rounds/521-a-cleanup-list-with-defects-in-it.md`, B-129
- **Round 586** — `:109` said all headers are HTTP headers, `:461` sent `te: trailers` as "required by gRPC-over-HTTP/1.1": `headers delivered 10 -> 9`. **The file's own doc is the cheapest oracle; measure where the thing STOPS** — `_createContextFromMessage` filters `te` and must stay for `rpc_dart_http2`. `../probes/P-206-what-te-trailers-reaches.md`, `../rounds/586-the-header-core-had-to-filter.md`, B-149
- **Round 883** — the gate's quiet command, documented "same exit status" as `test:unit`, exited 0 over a planted failure (`test:unit`: 1); 1 after escaping its `$`. **A gate whose failure path was never observed is prose about a gate.** `../probes/P-338-the-gate-over-a-planted-failure.md`, `../rounds/883-the-quiet-gate-cannot-fail.md`, B-302
