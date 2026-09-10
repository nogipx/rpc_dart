---
refines: U-22
paths: [packages/core/rpc_dart/lib/**, packages/transport/*/lib/**]
applies: a doc comment carries the search that produced the code
breaks: "wrong result: the comment is read as current when it records one moment, and the thing a caller needs is buried in it."
applied: [293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303]
status: confirmed (round 293)
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

  **Six files in six rounds, in three packages — this is a property of the
  corpus, not of core. Sweep for it explicitly.** A CLASS doc is the easiest to
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
