---
refines: U-21
paths: [.claude/loop/backlog/**, .claude/loop/checked/**, .claude/loop/lenses/**]
applies: the loop has more than a dozen rounds and records older than several of them
breaks: anything — a real defect hides behind a deferral; on this project that is how data loss was found.
applied: [201, 211, 232, 239, 247, 248, 249, 267, 278, 314, 319, 321, 329, 338, 339, 376, 378, 379, 380, 384, 396, 398, 408, 413, 429, 450, 457]
status: confirmed (round 457)
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
