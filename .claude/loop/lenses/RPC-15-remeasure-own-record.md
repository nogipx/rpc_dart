---
refines: U-21
paths: [.claude/loop/backlog/**, .claude/loop/checked/**, .claude/loop/lenses/**]
applies: the loop has more than a dozen rounds and records older than several of them
breaks: anything — a real defect hides behind a deferral; on this project that is how data loss was found.
applied: [201, 211, 232, 239, 247, 248, 249, 267, 278, 314, 319, 321, 329, 338, 339, 376, 378, 379, 380, 384, 396, 398, 408, 413, 429, 450, 457, 474, 537, 551, 555, 559, 561, 579, 588, 589, 596, 600, 601, 608, 612, 618]
status: confirmed (round 589)
---

# RPC-15 — Re-measure the loop's own record

U-21 instantiated for this project: the detector here is `loop.py stale`, not
reading records by eye, and its output is finite.

## Shape

A loop record — a lead, a negative, or a `swept here` status — made several
rounds ago and never checked since.

## Detector

`loop.py stale` in full; separately, records with `round: — (not re-measured)`
and sweeps marked «off-journal», which cannot be aged at all.

## Ask

Does the stated blocker still hold, and does the original probe still measure
what it measured then?

## Evidence

Re-measuring the deferral about the error-type split added a row the table had
never had — wasm — and that row held a silent stream truncation:
`items=11 events=[DONE]` instead of an error. Three deferrals re-measured in one
run, all three recorded wrongly.

Round 211: a claim the loop made about its OWN fix. Round 206 added a wake so
"a torn-down call can never leave a sender waiting forever"; round 210 ablated
it and nothing moved, which read as a no-op. Watching the right counter instead
of the call showed the opposite — 30 abandoned uploads leave 30 stranded senders
without it, 0 with it.

> **A record can be wrong about a fix's VALUE as easily as about a defect.**
> When an ablation shows nothing, suspect the observable before the code: round
> 210 was watching the call future, which resolves on a path the fix does not
> touch.

**Round 329 aimed it at a FOUR-ROUND-OLD lens instead of a stale one**, and that
is the variant worth keeping: RPC-26's `breaks:` line had consumed three rounds
and 534 edits without anyone testing it. Both halves were overclaims — no live
defect among the 534 (every test count unchanged at each round), and the floor
does not catch RPC-13's class, which round 242's own defect still demonstrates
at `client_connection.dart:432`.

> **The record most worth re-measuring is not always the oldest one.** `stale`
> ranks by age, so a claim made four rounds ago and acted on three times is
> invisible to it. Ask instead which record has been the most EXPENSIVE, and
> whether anyone tested it.

**Round 398 adds the cheapest trigger of all: a DEPENDENCY released.** B-53's
blocker was not a deferral of taste, it was a statement about someone else's
code — *"needs a stream-state getter package:http2 does not expose"* — and that
class of blocker expires without anyone here doing anything. `http2: 3.1.0`
closed it outright, P-73 reading 10 of 10 DEAD against 10 of 10 clean with the
version as the only variable.

> **Re-measure a lead whose blocker names a THIRD PARTY whenever that party
> ships.** `loop.py stale` cannot see this: it ages a record against paths in
> this repository, and the thing that changed is in `.pub-cache`. The changelog
> is the detector.

And the round's own failure is the warning attached to it: re-measuring means
reproducing the record's CONDITIONS, not just re-running its artefact. Five
green runs of the skipped witness said "no change" because every one was the
arm the record itself says passes anyway (L-17).

Round 321 is that note one level out, and it says the detector is not only
`stale`. A record can be a COMMENT a previous round wrote to explain its own
fix, and nothing ages those: round 314's said an aborted socket is answered by a
prompt read error rather than by `bodyReadTimeout`, which measured false — both
cost the server the same 2009 ms. The round that re-reads such a comment should
measure it, because it reads exactly like evidence and is a record of reasoning.

## Round 429 — a DECISION ages too, and it ages worse than a measurement

B-09 held three items. Two were already fixed when the owner decided what to do
about them, and the round that carried the decisions out is the first thing that
looked.

- item 2, "align the 504 row": already one shared table, `504 => unavailable`,
  **with a doc comment making the lead's own retryability argument almost word
  for word**. An earlier round did it and nothing told the lead.
- item 3, "measure shape (d) before fixing": does not reproduce. The expected
  `items=2, NO ERROR` reads `items=2, RpcStatusException` (P-97).

> **A lead that was never measured cannot go stale honestly — it was already a
> reading.** B-09's items came out of private memory with commits attached and
> no probe, so "verified against the code in the backlog review" meant read
> again, by the same method that produced them. Two survived that and neither
> survived a measurement.

The sharpest part is that the lead states the rule it broke, in its own item 3:
*"when deferring for blast radius, verify the specific thing you claim would
break, or the deferral is a guess wearing a reason's clothes."* It applied that
to round 89's revert and not to itself.

> **When a lead explains why ANOTHER record went stale, check the explanation
> against the lead.** The insight is usually general and the author usually
> thinks it is about someone else.

`../rounds/429-two-of-three-were-already-done.md`,
`../probes/P-97-truncated-stream-shape-d.md`.

## Round 450 — a record can be an unchecked NEGATIVE, and that is the cheapest kind to be wrong about

Everything above re-measures a claim the loop made about a DEFECT. Round 450
re-measured the loop's claims about non-defects: the `ff930001` sweep's list of
nine things it believed were already shared and therefore never reported.

Eight held. One did not — *"parity alignment in `RpcStreamIdManager`"* names the
class that owns the rule and stops there, and http2 does not use that class at
all.

> **A negative is a record like any other and ages like any other, but nothing
> routes to it.** A false positive costs a round and announces itself. A false
> negative costs nothing today and removes the question from the board, so the
> next reader inherits "settled" with no measurement under it. Re-reading the
> loop's own exclusion lists is therefore higher-yield per grep than re-reading
> its findings.

Method note worth keeping: check the entries that look most obviously true. The
two that nearly slipped were the two whose wording elsewhere in the journal
implies a second implementation — `drainUntilIdle` (whose COUNT is what bit
before) and the 5-byte frame (which B-78 describes as if http2 parsed it by hand,
where in fact `ensureGrpcFrame` calls the shared parser).

`../rounds/450-eight-held-one-did-not.md`,
`../checked/C-49-the-sweeps-nine-negatives-verified.md`.

## Round 457 — the record to re-measure was TWO ROUNDS OLD and the loop's own

Everything above re-measures somebody else's record, or one old enough to have
aged. 457's subject is round 455, committed the same day, by the same loop — and
the lead that found it, B-91, was filed as a pre-existing defect belonging to
nobody.

```
in process     compress 4096 -> 43, decompress 43 -> 4096  IDENTICAL
channel pair   every size, every spelling                  OK
http2          grpc-encoding: gzip                         status=13
```

The elimination order is the method: codec, then the in-process transport, then the
one that differs. What differed was the round two commits back.

> **A new lead whose paths were touched by a recent round is a suspect, not an
> inheritance.** B-91 was written as "pre-existing" on no evidence beyond the
> author not remembering causing it. `git log` over the lead's own `paths:` would
> have named the round in one command, and that check costs nothing.

And the reading rule the regression turned on:

> **A quote is evidence for what the quoted LINE does, not for what the variable
> HOLDS.** Round 455 cited `result.add(payload)` as proof the parser emits
> de-framed bodies. Twenty lines above, the compressed branch reassigns `payload`
> to a complete frame. Follow the variable to its assignments before quoting its
> use.

`../rounds/457-my-own-premise-was-false.md`,
`../probes/P-108-what-the-case-of-grpc-encoding-changes.md`.

## Round 474 — the record can be a STATUS, and the stale part its SCOPE

Every application above re-measures a CLAIM. 474 re-measured a status field.

B-85 sat at `decided by owner`, carrying `round: 453 — Dart half DONE; the
native half is untouched`. Both halves of that line are true, and together they
read as a decided job partly done. The decision itself says otherwise, in its
last paragraph:

> **The native half is NOT in this decision.**

So the decided work was finished twenty-one rounds ago and the remainder was
never chosen. I repeated the misreading in a report — *"B-85's native half can be
taken"* — which is what made it worth a round.

> **A lead's status describes the LEAD; a decision's scope describes the work.
> They drift apart the moment a decision covers only part of what the lead
> carries.** Read the decision's last paragraph, not the lead's title, before
> calling remaining work "decided and waiting".

> **An undecided remainder attached to a discharged decision is worse than a
> separate lead**, because every tool here reports it as work in progress and
> nothing distinguishes "not yet done" from "not yet chosen". Split it: B-93.

The check itself is the ordinary one — the decision's own bar (*"no literal
appears twice"*) against today's tree, not against the round that claimed it.
What made it convincing was a field added AFTER the decision, round 462's
`contentTypeValidation`, which followed the idiom without anyone re-reading the
lead.

`../rounds/474-a-decision-discharged-and-a-tail-split-off.md`.

**Round 537 — an external lead reopened a negative, and the negative held.**
B-141's first half is C-31's question from round 273, re-run at today's sha rather than
cited: the same `408` to the peer, the same `384 KiB` of socket buffer, against a control
that takes `4096 KiB` and answers nothing. Its second half was true as a FACT and harmless
in effect, for the reason C-31 already gave.

`../probes/P-170-does-the-rejection-drain-run-at-all.md`,
`../checked/C-31-the-408-really-does-stop-the-read.md`, B-141.

> **An outside audit reopening a negative is a reason to re-run it, not to cite it.**
> The audit read the same code and reached the older conclusion; what settles it is the
> number, and a negative worth keeping is one that reproduces.

> **A stand-in for the code under test measures its author.** This round's first probe used
> a hand-written server in place of the transport and reported `closed with nothing` where
> the real thing reports `408` — differing in exactly the detail under test. Plausible, and
> wrong.

> **An over-specified control fails for the right reason and the wrong claim.** The first
> control asserted a pre-read 415 reaches a slow-body peer. It does not, and deliberately:
> the drain is deadlined, so a body that never arrives is answered by a teardown. The arm
> was asking for what an earlier round had chosen to give up — check whether a control
> contradicts a decision before believing it contradicts the code.

**Round 555 — the record to re-measure was THREE ROUNDS old, and what was stale was its COVERAGE.**
Round 552 changed stream lifecycle and witnessed one shape. Bidi reads `4372 -> 4372, charged/msg
15 B, sendCredit: 1` with the fix and `250569 -> 496486, sendCredit: 0` with it ablated — so the
shape DID have the defect and the one condition does cover it.

`../rounds/555-the-shape-nobody-had-measured.md`, B-218.

> **"Fixed by construction" is a prediction, and this lens is for predictions the loop makes about
> its own fixes.** The argument for bidi was identical to the argument for server-stream, and that
> argument had already been wrong once — an inbound end-of-stream being the end of the call is
> "obviously" fine until a shape half-closes early. The cost of checking was one probe block.

> **Report the gate failure you could not reproduce, and file it.** A websocket test failed once
> under `load average 9.62` on a `health()` key that had answered seconds earlier, with `lib/`
> byte-identical to its committed state. Re-running until green and saying nothing would have been
> the easy path; B-219 exists because a diagnostic that can omit a key it documents is a defect in
> the diagnostic whatever made it fire.

**Round 559 — the record to re-measure was the SELECTION RULE, and the evidence was three rounds of
this loop against each other.** `B-154` real and worth nothing, `B-178` severity refuted, `B-184` real
and severe — all three from one intake, worked consecutively, and the list they came from was being
read in title order.

`../rounds/559-the-intake-was-unsorted-not-empty.md`,
`../checked/C-61-the-audit-intakes-severity-claims-do-not-hold.md`.

> **A flat list of leads IS a record, and it ages like one.** Every entity here has a status that
> `stale` can age, except the ordering among them — so a list assembled by an outside audit keeps its
> author's grading forever unless someone re-grades it. Three rounds disagreeing with each other is
> what made the ordering visible as a claim.

> **Grade by CONSEQUENCE, not by subject.** Two entries read as somebody else's problem and are not:
> one whose two ends are both this library, and one whose cost is every future round's evidence.
> Sorting by the file a lead names reproduces the audit's own mistake.

> **Sorting needs no owner decision; only acting on the sort does.** Round 556 asked whether to
> re-grade and got no answer, and three more rounds then picked by title. The question that needed
> answering was narrower than the one asked — what to DO with the parked class — and the pass could
> have happened at any time without it.

**Round 561 — two comments about ONE call, 25 lines apart, saying opposite things.**

```
/// `HttpServer.close(force: false)` is NOT a drain ... completes as soon as the port is released
    // `close(force: false)` stops accepting AND waits for what is already running
```

`../rounds/561-two-comments-about-one-call-disagreed.md`, B-151.

> **A contradiction between a doc comment and an inline one is invisible to the reading that finds
> either.** Reading the method shows the inline comment and the code; reading the API shows the doc.
> Nobody reads both at once, which is how they drifted apart and why the audit's line numbers were
> the only thing that pointed at it. When checking prose against code, check the prose against the
> OTHER prose about the same call.

> **The dangerous stale comment is the one that gives a REASON, not the one that misinforms.** "Does
> double duty" made the explicit drain below it look redundant — so believing it leads to deleting the
> only thing that waits, and the correct comment three lines above describes exactly the hang that
> follows. A wrong fact costs a reader a minute; a wrong justification costs the next refactor.

## Round 588 — the record to re-measure was the previous round's own GATE section

Every application above re-measures a finding, a negative or a bench. 588
re-measures a round's `## Gate` — the part nobody treats as a claim.

Round 587 hit a red on a test its change could not reach, and wrote: *"load average
11.37 against `config.md`'s quiet-machine bar"*. Four true facts were offered with
it — another package, passes alone, five green runs before, high load. Round 588
varied the named variable and the explanation collapsed:

```
14 busy isolates in another process, load 84.76   waiters 1   clean
dart test --concurrency=24                        waiters 0   RED
```

Eight times the load that was blamed, and clean. The variable was the test runner's
own suite concurrency — `~16 suites on 8 cores` — which is not CPU pressure from
elsewhere and is not what the sentence said.

> **"It is a flake" is a hypothesis that NAMES a variable, and a round that writes
> one down without varying it has filed a guess as a finding.** The four
> circumstantial facts all survive into the correct explanation, which is exactly
> why they feel sufficient: they establish that something environmental is involved
> and then the first environmental word to hand gets recorded as the cause.

> **Ask for the MARGIN.** The arm slept 250 ms for a park that needs 5-25 ms — 10-50x,
> not the 250x it reads as. That one number turns "mysteriously flaky" into
> "insufficient headroom against a named quantity", which is fixable, and it took one
> probe. Any wall-clock assertion has a margin and almost none of them state it.

The failure mode this lens is for: a `## Gate` section is prose about the
environment, so nothing in `lint`, `stale` or the round schema ever asks it for
evidence — and the lead it spawns inherits the wrong variable. `L-19`.

`../probes/P-208-how-much-margin-a-timing-assertion-has.md`,
`../rounds/588-the-gate-oversubscribes-its-own-cores.md`, B-224.

> **Round 589's addition, from ablating the arm 588 had just rewritten: an instrument
> that reads state AFTER a teardown reports clean whatever happened.** The new
> observable was the reassembly buffer's size, and both paths that would read it have
> already reset it — a completed frame compacts the buffer, `_failChannel` drops it
> outright. So the ablation PASSED, and the replacement instrument was as blind as the
> proxy it replaced. The fix is a high-water mark. Ablate every rewritten arm, not
> only the one whose failure started the round: a fix to an instrument is a change to
> what the test can see, and nothing else checks that.
