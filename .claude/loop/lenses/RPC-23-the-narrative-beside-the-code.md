---
refines: U-22
paths: [packages/core/rpc_dart/lib/**, packages/transport/*/lib/**]
applies: a doc comment carries the search that produced the code
breaks: "wrong result: the comment is read as current when it records one moment, and the thing a caller needs is buried in it."
applied: [293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 304, 305, 306, 333, 337, 364, 375, 381, 401, 404, 432, 435, 436, 437, 438]
status: confirmed (round 432)
---

# RPC-23 — The narrative beside the code

## Shape

A doc comment that tells the story of how the code came to be: the measurement,
the arms, the wrong turn, the sibling that had it right. Every sentence was true
when written. Together they are unreadable by the person the comment is for, and
unmaintainable by the person who changes the code.

The tell is a comment that answers *how did we find this* rather than *what do I
pass here*.

## Detector

Per file, **ALL comment lines** — `///` AND `//` — against total lines. Above
~20% the file is prose with code in it. Then, per comment, three questions:

> **The density RANKS where to sweep; it does not decide whether to.** Round 302
> took `rpc_dart_isolate` at **18.2%**, under the threshold, and found the worst
> fusion of the whole series: one `//` block carrying two subjects, the first
> describing code 76 lines below it. The adjacency shape is INDEPENDENT of
> density — a lean file hides it better, because there is no bloat to prompt a
> reader to look. Never read a sub-threshold number as "this package is clean".

> **Counting only `///` measures a third of the problem.** Rounds 293-296 ranked
> by doc lines alone and reported files finished that were not: measured at 297,
> `channel_transport.dart` still stood at 564 comment lines in 1338 (42%) the
> round after it was "done", and `transport.dart` at 236 in 533 (44%). The
> narrative does not live in the doc comment. It lives in the `//` block INSIDE
> the method, next to the line it explains — which is exactly where a
> measurement table ends up, because that is where the author was standing.
>
> Core's real baseline is **6539 comment lines in 23718 (27.6%)**, against the
> 4430/24049 (18.4%) the `///` metric reported.

1. **Is there a measured table in it?** A table is a record of one run, on a tree
   that has moved. It belongs in the round record, which is dated and which
   `stale` ages; the comment cannot be aged by anything.
2. **Does it name rounds, commits, siblings or "an earlier version of this
   comment"?** That is journal content addressed to a reader who has the journal.
3. **Could a caller choose a value without it?** Keep exactly what answers that
   plus the one limitation that changes the choice. Everything else goes.

## Ask

If this comment were deleted, what would the next caller get wrong?

**On INTERNAL code the reader changes and so does the question.** A private
field has no caller; it has a maintainer about to change it. Ask instead: *what
would someone editing this break without knowing?* The keeper is the INVARIANT
— why the charge point is dispatch and not entry, why the cursor must survive
close, why this counter is per connection — because that is what a plausible
edit destroys silently.

The measurement that PROVED the invariant is still journal. "37 handlers against
a ceiling of 4" belongs in the round; "charged at dispatch, released when the
handler finishes, because a stream can die before its work does" belongs in the
code. The first is evidence, the second is the rule the evidence bought.

Whatever survives that question is the comment. It is usually three to six
lines, and for a field it is usually: what it bounds, why the default is what it
is, and the one case where the obvious value is wrong.

## Evidence

**`RpcSecurityPolicy`, round 293.** 236 doc lines in a 451-line file — every
field an essay with its own measurements. Four fields carried 127 of them:

    field                        before  after
    maxActiveStreams                 33      7
    maxConcurrentHandlers            43     11
    closeOnProtocolError             17     10
    halfOpenStreamTimeout            34     13

    file total                      236    151

Nothing was lost: the tables live in rounds 205, 213-215 and 245, which is where
a reader who wants the history should have to go, and which `loop.py stale` ages
against the code. What a caller needs — this bounds stream STATE not running
handlers, use `maxConcurrentHandlers` for the work; null by default because
turning it on trades slow for refused — survives in a quarter of the space.

> **The comment cannot be aged, so it must not carry what ages.** A measured
> table beside the code is a claim with a timestamp nobody can see. The journal
> has dates, shas and a linter; the comment has none of those, and rule one
> already says prose goes stale silently. That applies hardest to prose that
> looks like evidence.

## The unit is a BATCH OF FILES

Rounds 293-295 cut four comment blocks each and moved 149 lines against a
baseline of 4430 — the owner stopped it. 296 moved to one file per round and the
owner stopped that too, for the same reason: at 92 files in core alone, one per
round does not finish either.

Read several files whole, cut every comment in one pass, one gate, one commit.
The ranking gives the order; the two reader questions above give the rule.
Neither needs re-deriving per block or per file.

**And the sweep sees what a single block cannot: adjacency.** Three kinds, all
found by sweeping and none reachable block by block:

- **A doc fused to the wrong declaration.** Round 296: `_validateInbound`'s
  comment ran into `_maxPolicyViolations`' with no declaration between them, so
  both attached to the constant — one member undocumented, the other's reading
  as if the first half described it. Round 297 found the same shape at
  `_reclaimGrace`, wearing `_onDeadlineExceeded`'s description. Round 298 found
  the worst case: `_normalize` carried `register`'s ENTIRE doc, code sample
  included, and `register` carried the same nine lines again twenty lines later,
  so the same instruction appeared twice with no way to tell which was current.
  Round 299 showed a fused doc can HIDE something, not just misattribute it:
  `_uniqueToken`'s description sat on `_strongRng`, so the function minting every
  request id had no doc at all — and the fact that `Random.secure()` THROWS on
  node, making those ids non-cryptographic, was buried under a heading about a
  different member. Round 300 found it on the first package swept OUTSIDE core,
  and on a PUBLIC declaration: `RpcWebSocketChannel`'s description and code
  sample had fused onto `grpcStatusFromWebSocketCloseCode`, so the exported class
  the library doc tells you to construct had no doc, and the close-code mapper
  wore a `RpcChannelTransport.fromChannel` sample.

  Round 301 found the sixth, in a third package, and established what it
  actually COSTS: `_readBounded`'s doc sat on `_readErrorBody`, and the LSP
  hover for `_readBounded` returned **signature only** before the fix and the
  docstring after it. A fused doc is not merely hard to read, it is INVISIBLE to
  every tool that reads docs by symbol — an IDE, `dart doc`, and any
  symbol-based agent. That also makes it the one sub-shape here with a real
  witness: query the hover before and after.

  **Eight instances by round 305, in five packages, and it lands on every KIND
  of declaration** — a public class (300), a private method (301), a local `//`
  block (302), a private method again (303), a typedef (304), and a static
  function whose doc was eaten by a `const` 67 lines above it (305). It is
  independent of the declaration kind, of comment density (302), and of package.
  What it depends on is a blank line between a doc and the thing below it, which
  nothing checks. **Sweep for it explicitly.** A CLASS doc is the easiest to
  lose this way: it and its declaration are separated by exactly the blank line
  that hides the fusion, and it is the doc a user reads first.
- **PARAGRAPH fusion**, the milder variant — two paragraphs of ONE doc run
  together with no blank `///` between them, so they render as one paragraph and
  the second subject is swallowed by the first. Round 301 found three in a
  single package: `stop()`'s idempotency argument swallowing `[drainTimeout]`'s
  description, a TLS warning swallowing `[policy]`'s, and `_reject`'s CORS
  rationale swallowing the body-drain one. Nothing catches it — the compiler
  sees one valid doc, and the text is correct line by line.
- **A block duplicated verbatim.** Round 297: eight lines about timer-vs-
  microtask delivery appeared TWICE in a row in `getMessagesForStream`. Each
  copy is correct, which is why nothing caught it.

  **Round 304 found the CAUSE of one: a doc left behind when its code MOVES.**
  `RpcHttp2OutgoingPump` moved to `rpc_http2_common.dart` and took its doc; the
  `typedef _OutgoingPump = RpcHttp2OutgoingPump;` left behind kept a 29-line
  verbatim copy, ending in a line saying the real one is elsewhere. Both copies
  correct, in two files, one attached to a one-line alias. Sweep for this around
  any `typedef`, re-export or thin wrapper — those are what a move leaves
  behind.
- **The same measurement in two places.** The pre-method budget's 789 MiB and
  the deadline reclaim's `openStreams: 30` were each written once as a doc
  comment and once as an inline block a few hundred lines apart.

Sweep for comment runs that span a blank line, change subject mid-block, or
repeat a phrase already present in the file.

## The sweep also finds prose that is WRONG, not just long

Round 302: `isolate_transport_stub.dart` called itself the fallback "for
platforms without `dart:isolate` (e.g., web)", while the conditional export
three lines away routes `dart.library.js_interop` to a real Worker-backed
implementation. The one platform named as the example is the one that never
reaches the file.

No gate catches this — the compiler does not read prose, and the contradicting
evidence lived in a different file. It is rule one applied to a comment: the
implementation first, and a divergence is a defect fixed in the same round.

**Fixing one COSTS lines**, and that is correct. The stub went 5 comment lines
to 9 while the package fell 221 to 192. A round that optimised the metric would
have made the only false statement in the package worse.

**The sweep is the only pass that READS every comment**, so it is also the only
one that sees a comment wrong in a way no gate reads. Round 303 found three such
things in one batch, none of them bloat: a declaration fusion, a misspelling in
a public doc (`"Gárrantees"`), and an entire file — `rpc_http2_server.dart`,
class doc, parameter list and every runtime log string — written in RUSSIAN,
against the root `CLAUDE.md`'s "English for code, comments, and logs". The
language check is cheap and worth running per package:
`grep -rlE "[А-Яа-яЁё]" packages/*/*/lib`. It found 22 more files outside the
mandate, filed as B-30.

## What NOT to cut

A comment earns its place by saying what BREAKS if the code is undone — one or
two lines, per `config.md`. That is not narrative and it is the thing most worth
keeping: `_reject`'s "dart:io tears the connection down before the status is
flushed" is why the drain exists, and a future reader who deletes the drain
without it will reintroduce the bug.

Cut the how-we-found-it. Keep the what-breaks-if-you-undo-it.

## The worst kind: prose that CAUSES the defect (round 333)

Most of what this lens cuts is inert — a stale story, a table from a round
record, evidence nobody will re-check. `LogScope.noop` carried a different
species:

```dart
/// No-op logger. All methods are empty, zero cost.
```

The methods are empty; the CALL is not free. `internal(String message, ...)`
takes a String, so Dart builds the interpolation at the call site before the
empty body is entered. Measured on one unary round trip with no logger attached:
**35 discarded messages, 1566 characters, ~2.0 us of CPU on the VM and ~3.5 us
on dart2js.** The same class exposes `isInternal` "for hot-path optimization",
used at 25 of 58 interpolating sites — and the per-call unary responder had 38
calls and zero guards.

> **A doc comment that states a COST is load-bearing, and wrong ones are
> expensive in a way stale narrative is not.** Stale narrative misleads a reader
> about history; "zero cost" told every author not to guard, and they did not.
> When a comment makes a performance or safety claim, measure it or delete the
> claim — do not carry it forward because it is short.

## Round 364 — prose that names a component which cannot do the job

The strongest form of this shape found so far, and the cheapest to detect.
`rpc_dart_wasm`'s README said the iOS backend was **JavaScriptCore**, twice.
JSC has no WebAssembly, so if it were true the package could not run a
dart2wasm guest on iOS at all — and it does, through an offscreen `WKWebView`
with a custom scheme handler.

> **Some stale prose is not merely out of date, it is IMPOSSIBLE.** A claim you
> can refute from the component's own capabilities needs no diff archaeology:
> ask what the named thing can do, and whether the package works. Faster than
> comparing against the code, and it caught both mentions at once — a search for
> the component NAME finds them where a read-through does not.

> **Write the reason next to the correction or it comes back.** The fix says
> "JSC has no WebAssembly, so it cannot run a dart2wasm guest at all", not just
> "WKWebView". A bare correction invites the next reader to swap it back.

Same round, the inverse duty: a README is also where a missing measurement does
damage. The item asked for the price of a frame, the README gave none, so it was
measured — `p50 12.9 ms` for an empty unary on an Android emulator, flat to
1 KiB because the price is the boundary rather than the payload. Published with
the hardware named and the shape explained, since an emulator is a floor and not
a prediction.

> **And a claim written INTO prose must be verified before it ships, even when
> its source is the repository's own comment.** The websocket note about
> `dart:io` buffering a whole message came from a source comment — exactly what
> this lens says not to trust. Running the existing probe turned it into
> `96 MiB sent -> 1 chunk -> 96 MiB` before it reached a README people deploy
> from.

Bench `../probes/P-55-what-a-wasm-call-costs.md`,
`../rounds/364-the-readme-named-an-engine-that-cannot-run-it.md`.

## Round 401 — the prose that is thrown, not written

Round 364's form is a README naming a component that cannot do the job. Round
401's is the same defect in the one place prose is reached at RUNTIME, by a
reader who is already in trouble: an **error message that prescribes**.

`RpcWebSocketServer.start()` refuses to restart over a single-subscription
stream and names two remedies. Driven literally, "construct a new
`RpcWebSocketServer`" throws the identical error — the obstacle is the STREAM,
and over the same `HttpServer` there is no fresh one to be had. And the remedy
that does work has a window the message did not mention, in which a peer is
accepted and abandoned.

> **A message that tells the user what to do is a promise the compiler cannot
> check, read at the worst possible moment.** Grep for the imperative voice in
> `throw` arguments — "pass", "use", "construct", "call X first" — and drive
> each one the way a reader would: change only what the sentence says to change.

`../rounds/401-the-remedy-that-was-not-one.md`, and the bench is RPC-21's
`../probes/P-87-restart-the-way-the-error-says.md`, because driving the remedy
IS driving the lifecycle twice.

**Round 404 counted the class and sharpened the detector, which is the more
useful half.** 228 `throw` sites in the 22 packages' `lib/`; about 20 prescribe
an action. Driving the three highest-risk members — `RpcApp`'s "create a new
RpcApp to restart", and both copies of "call reconnect()" — found all three
correct, including both halves of the two-claim sentence on both transports.

> **The tell is not "a message that prescribes". It is a message that prescribes
> rebuilding A when the state that blocks you is held by B.** `RpcApp` says
> rebuild the thing that actually holds the single-shot state, and its factory
> takes a server BUILDER, so the closure rebuilds what cannot be re-listened.
> The websocket server said rebuild the server when the obstacle was the stream.
> Rank the class by that question and the rest of it — `call X first` guards on
> an object's own API, where the obstacle and the named object are the same
> thing — drops to the bottom without needing to be driven.

Second rule the arms earned: **split a sentence with an `and` in it.** "Call
reconnect(), and a failed reconnect leaves the transport recoverable, not
closed" is two assertions, and "recoverable" buys nothing if it only means
`isClosed == false` — so the failing arm has to go on and try a LATER reconnect.
Both did succeed. `../probes/P-89-drive-what-the-message-prescribes.md`,
`../rounds/404-what-the-messages-promise.md`.

## Round 435 — prose has three audiences, not one, and a grep sees one class

B-30 sweeps Cyrillic out of a repo whose own rule says "English for code,
comments, and logs". Two measurements from the transport half.

**A text-matching detector cannot tell prose from a fixture.** Three of the
eight transport test files with Cyrillic must keep it: `'Ошибка'` is asserted to
percent-encode to ASCII on the wire, `'кириллица' * 6` proves a close reason is
measured in bytes rather than characters, and the wasm test round-trips UTF-8
through the native bridge. In each, the non-ASCII-ness IS the subject. The lead
called its grep "both the detector and the check", and the check would have
demanded breaking all three.

> **A detector for a prose defect returns prose AND data.** Before acting on one
> of its hits, ask what the line is FOR. The same grep that finds a Russian
> comment finds the fixture whose whole point is to be Russian — and the second
> kind cannot be fixed, only recognised.

Scope, too: run over paths rather than `git ls-files`, that grep returns ten
gitignored Android resource-merge artifacts in nine languages nobody here wrote.

**The audiences are separate and the counts are not interchangeable:**

    comment in test/   a maintainer who opened the file
    comment in lib/    that, plus dartdoc on the pub.dev package page
    LOG in lib/        emitted at runtime into the user's own log stream

The third is the one a reader cannot avoid — no file needs opening, and turning
it off means turning the logger off. Counted on that axis, the largest single
concentration in the repo is `rpc_notify/lib/src/stream_distributor.dart`: 176
lines, 137 comments and **39 runtime log messages**, more than any test file.
B-30 had never counted the third category, and neither had this lens.

Emoji, swept under the same rule, have a different distribution entirely: 154
lines across 14 files, every one of them `test/` or `example/`, none in `lib/`.

> **Two style rules stated in one sentence are still two populations.** Count
> each separately before deciding which to sweep; "no emoji and English
> everywhere" hid the fact that only one half had reached shipped code.

`../rounds/435-the-half-that-ships.md`, `../backlog/B-30-russian-comments-outside-the-mandate.md`.

## Round 436 — the fixture that fails SILENTLY when you translate it

435 said a text detector cannot tell prose from a fixture. 436 censused the
whole fixture class into `../checked/C-47-the-non-ascii-that-must-stay.md` and
drove three of them, which is where the useful half is: **they do not all fail
the same way, and the majority do not fail at all.**

```
cbor_test.dart:138        '☺' -> ':)'                   FAILS -- hex pinned
audit_header_ascii:27     'тест 🚀' -> 'test rocket'    FAILS -- assertion inverts
optimized_cbor:164        'Привет, мир!' -> 'Hello...'  PASSES
```

A round-trip fixture asserts `decoded == original`, which holds for any string.
Translate it and the suite stays green while the coverage it existed for —
multi-byte UTF-8 through this codec — is gone. Ten of the twelve sites in C-47
are that shape; only two fail loudly.

> **Before sweeping prose, ask which hits would fail if you were WRONG.** "The
> gate would catch it" is an assumption, and for a round-trip assertion it is
> false: the test is written to accept any value, so the data it was given
> stops mattering the moment you change it.

Second measurement, on the detector rather than the data. `[а-яА-Я]` is
script-specific, so it cannot enumerate the class it keeps hitting: it flags
`optimized_cbor_test.dart:167` only because `'Hello 🌍 Мир 世界'` contains
`Мир`, and is blind to `'你好世界'` and `'مرحبا بالعالم'` two lines above in the
SAME map literal, and to `'世界' * 5000` in the sibling file — 10,000
characters, the largest unicode fixture in the repo.

And the split changes SHAPE between packages: per FILE in transports (3 of 8
flagged files pure fixture), per LINE in core, where `cbor_test.dart` holds
comments to translate at `:148` and fixtures not to at `:135`.

> **A `grep -rl` detector answers "which files", and some classes only have an
> answer at "which lines".** When a sweep starts re-flagging the same sites,
> that is the signal the unit is wrong — not that the sweeper was careless.

`../rounds/436-the-detector-that-cannot-see-its-own-class.md`, `../checked/C-47-the-non-ascii-that-must-stay.md`.

## Round 437 — prose nobody reads is prose nobody checks

The rule this lens serves is usually argued as style. Round 437 found the
version that is not.

```dart
expect(avgTime, lessThan(10000)); // < 3ms среднее время
```

10,000 microseconds is 10 ms. The comment had been wrong since it was written
and nobody noticed, because a reviewer who skips a language they do not read
skips the CLAIM inside it too. The sibling comment one line down was correct,
so this was not a systematic slip — it was an unchecked one.

> **A comment in a language the reviewers do not read is not merely unhelpful;
> it is exempt from review.** That is the argument for the rule that does not
> depend on anyone's preference: translating it is what subjects it to the same
> scrutiny as the code beside it.

**And a lint can mandate the ambiguous form.** `$minTimeμs` reads as one
identifier and is not — `μ` is not an ASCII letter, so it ends the name and
`μs` is a literal. Round 435 met that shape and mis-edited it into an undefined
identifier. The obvious repair, `${minTime}μs`, is refused:

```
info - Unnecessary braces in a string interpolation - unnecessary_brace_in_string_interps
```

and `analyze` is `--fatal-infos`, so that is a build failure. The analyzer knows
the boundary from the grammar and calls the braces redundant, which removes the
only signal a human has.

> **"Unnecessary" in a lint means unnecessary TO THE PARSER.** Where a
> disambiguator exists for the reader and the compiler does not need it, the
> rule and the reason for the rule point opposite ways. Comment the site; the
> config is the owner's to change, not a round's.

`../rounds/437-the-lint-that-mandates-the-ambiguous-form.md`.

## Round 438 — the second one, which makes it a rate

437's stale comment could have been an accident. 438 swept a comparable volume
and found another, in the second file it opened:

```
437  fast_cbor_encoder_test.dart:144    "< 3ms"  on lessThan(10000)  -- 10 ms
438  rpc_context_validation_test.dart   "100мс"  on milliseconds: 1
```

Both state a NUMBER a reader could check against the line below in one second.

The 438 case is the more instructive: `git log -S` shows the timer WAS
`milliseconds: 100` when the comment was written, and became `1` in a later
commit. **It was not wrong when written. It drifted, and the drift was
invisible** — a reviewer skipping a language they do not read cannot notice that
the number beside it moved.

> **Comments in an unread language do not merely go unwritten-for; they go
> un-maintained.** Every ordinary edit that moves a constant leaves them behind,
> and the usual defence — someone reads the diff — is exactly what does not
> happen there. Expect drift concentrated in that subset, and check the numbers
> as you translate.

`../rounds/438-the-comment-that-was-right-once.md`.
