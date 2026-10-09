---
refines: U-21
paths: [.claude/loop/backlog/**, .claude/loop/checked/**, .claude/loop/lenses/**]
applies: the loop has more than a dozen rounds and records older than several of them
breaks: anything — a real defect hides behind a deferral; on this project that is how data loss was found.
applied: [201, 211, 232, 239, 247, 248, 249, 267, 278, 314, 319, 321, 329, 338, 339, 376, 378, 379, 380, 384, 396, 398, 408, 413, 429, 450, 457, 474, 537, 551, 555, 559, 561, 579, 588, 589, 596, 600, 601, 608, 612, 618, 620, 621, 622, 623, 629, 657, 663, 670, 672, 674, 729, 730, 740, 741, 742, 760]
status: confirmed (round 730)
rank: 16
---

# RPC-15 — Re-measure the loop's own record

U-21 instantiated for this project: the detector here is `loop.py stale`, not
reading records by eye, and its output is finite.

## Shape

A loop record — a lead, a negative, a `swept here` status, a decision's scope, a
comment a round wrote to explain its fix, a round's `## Gate` section, or the
ordering of a lead list — made some rounds ago and never checked since.

## Detector

`loop.py stale` in full; separately, records with `round: — (not re-measured)`
and sweeps marked «off-journal», which cannot be aged at all. `stale` cannot see:
a young but EXPENSIVE record, a blocker naming a THIRD PARTY that has since
shipped (the changelog in `.pub-cache` is the detector), a comment, a status, a
gate section, or a list's ordering. For a new lead, `git log` over its own
`paths:` before calling it "pre-existing".

## Ask

Does the stated blocker still hold, and does the original probe still measure
what it measured then? Re-measuring means reproducing the record's CONDITIONS,
not just re-running its artefact.

## Evidence

Re-measuring the deferral about the error-type split added a wasm row that held a
silent stream truncation (`items=11 events=[DONE]` instead of an error); three
deferrals re-measured in one run, all three recorded wrongly.

- **Round 211** — round 206's wake looked like a no-op when round 210 ablated it;
  the right counter showed 30 stranded senders without it, 0 with it. A record
  can be wrong about a fix's VALUE; when an ablation shows nothing, suspect the
  observable before the code.
- **Round 321** — round 314's comment (an aborted socket gets a prompt read error,
  not `bodyReadTimeout`) measured false, both cost 2009 ms. A comment explaining a
  fix reads like evidence and is a record of reasoning; measure it.
- **Round 329** — RPC-26's `breaks:` line, four rounds old, had driven three
  rounds and 534 edits untested; both halves overclaimed (RPC-13's class still
  shows at `client_connection.dart:432`, round 242). The record most worth
  re-measuring is the most EXPENSIVE, not the oldest.
- **Round 398** — B-53's blocker on `package:http2` expired with `http2: 3.1.0`
  (P-73: 10 of 10 DEAD vs 10 of 10 clean). Re-measure a lead whose blocker names a
  third party whenever that party ships; five green runs of the arm that passes
  anyway said nothing (L-17).
- **Round 429** — B-09: two of three items were already fixed (item 2's 504 row,
  `504 => unavailable`), item 3 did not reproduce (P-97, `items=2,
  RpcStatusException`); it had been re-read, never measured, and broke its own
  rule about round 89's revert. A lead never measured cannot go stale honestly;
  when a lead explains why ANOTHER record went stale, check the explanation
  against the lead. `../rounds/429-two-of-three-were-already-done.md`,
  `../probes/P-97-truncated-stream-shape-d.md`.
- **Round 450** — of the `ff930001` sweep's nine negatives, eight held; "parity
  alignment in `RpcStreamIdManager`" did not (http2 does not use it). A negative
  ages like any record but nothing routes to it, so re-reading exclusion lists is
  higher-yield per grep; check the most obviously true entries (`drainUntilIdle`,
  the 5-byte frame B-78 describes, `ensureGrpcFrame`).
  `../rounds/450-eight-held-one-did-not.md`,
  `../checked/C-49-the-sweeps-nine-negatives-verified.md`.
- **Round 457** — B-91, filed as pre-existing, was round 455's own regression:
  http2 `grpc-encoding: gzip` gave status=13. A new lead whose paths a recent
  round touched is a suspect, not an inheritance; a quote is evidence for what
  the quoted LINE does, not what the variable HOLDS.
  `../rounds/457-my-own-premise-was-false.md`,
  `../probes/P-108-what-the-case-of-grpc-encoding-changes.md`.
- **Round 474** — B-85's decided work was done in round 453 (twenty-one rounds
  earlier, checked against round 462's `contentTypeValidation`) and its decision
  says "**The native half is NOT in this decision.**" A lead's status describes
  the LEAD, a decision's scope the work; an undecided remainder attached to a
  discharged decision is worse than a separate lead, so it was split to B-93.
  `../rounds/474-a-decision-discharged-and-a-tail-split-off.md`.
- **Round 537** — B-141 reopened C-31 (round 273); re-run, it held: `408`, 384
  KiB against a 4096 KiB control. An outside audit reopening a negative is a
  reason to re-run it; a stand-in for the code under test measures its author; an
  over-specified control may contradict a decision, not the code.
  `../probes/P-170-does-the-rejection-drain-run-at-all.md`,
  `../checked/C-31-the-408-really-does-stop-the-read.md`, B-141.
- **Round 555** — round 552's lifecycle fix, three rounds old, had witnessed one
  shape; bidi did have the defect and the fix covers it (`4372 -> 4372` vs
  `250569 -> 496486` ablated). "Fixed by construction" is a prediction; report a
  gate failure you could not reproduce and file it (B-219).
  `../rounds/555-the-shape-nobody-had-measured.md`, B-218.
- **Round 559** — `B-154`, `B-178`, `B-184` from one intake, worked in title
  order, disagreed on severity. A flat list of leads is a record and ages; grade
  by CONSEQUENCE, not subject; sorting needs no owner decision, only acting on it
  does (round 556 waited on one).
  `../rounds/559-the-intake-was-unsorted-not-empty.md`,
  `../checked/C-61-the-audit-intakes-severity-claims-do-not-hold.md`.
- **Round 561** — a doc comment and an inline comment on `HttpServer.close(force:
  false)`, 25 lines apart, contradicted each other. Check prose against the OTHER
  prose about the same call; the dangerous stale comment gives a REASON.
  `../rounds/561-two-comments-about-one-call-disagreed.md`, B-151.
- **Round 588** — round 587 blamed "load average 11.37"; varying it, load 84.76
  was clean and `--concurrency=24` was red (~16 suites on 8 cores). "It is a
  flake" names a variable and must vary it; ask for the MARGIN (250 ms against a
  5-25 ms park is 10-50x). A `## Gate` section is never asked for evidence (L-19).
  `../probes/P-208-how-much-margin-a-timing-assertion-has.md`,
  `../rounds/588-the-gate-oversubscribes-its-own-cores.md`, B-224.
- **Round 589** — an instrument that reads state AFTER a teardown reports clean
  whatever happened (`_failChannel` drops the buffer); use a high-water mark and
  ablate every rewritten arm.
