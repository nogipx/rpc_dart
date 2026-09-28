---
round: 474
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: none — the claim is that an owner decision is discharged, so the evidence is the decision's own bar checked against the tree
commit: yes
---

# Round 474 — a decision discharged, and a tail split off

## Target

B-85, which I reported last round as "takeable now that the devices work". That
was wrong, and re-reading the decision is what shows it:

> **The native half is NOT in this decision.** The JS shim carried as strings in
> both Swift and Kotlin stays a separate, device-bound job.

So there was never a decided native job to take. What the owner decided was the
Dart half, and round 453 did it. The lead has been sitting `decided by owner`
with its decision already discharged, carrying an UNDECIDED tail — which reads,
to every tool here and to me, as work in progress.

## Hypothesis

The decision is complete against its own stated bar, and what remains is a
different lead.

## Before

```
B-85 status        decided by owner (round 445)
B-85 round         453 — Dart half DONE; the native half is untouched
the decision       "one source for the defaults, plus the test"
its bar            "no literal appears twice"
```

## The measurement

The bar, checked against the tree rather than against round 453's report:

```
default literals outside the _default* block    none
what is left                                    Duration(milliseconds: ms) from a
                                                PARSED int; 0x20/0x7F/0x0D/0x0A
                                                character checks in the header
                                                validators
```

Neither is a default with two homes.

**And the shape held under the first field added after the decision**, which is
the part worth having: round 462's `contentTypeValidation` went in through the
same idiom — constructor, `toMap`, `fromMap`, one `_default` constant — without
anyone re-reading this lead. `policy_defaults_agree_test.dart` is green in every
gate run this session, and it is what would have caught a literal written back.

## Mechanism

None in `lib/`. The change is to the journal: B-85 closed, its undecided tail
filed as **B-93**.

## After

```
B-85    closed (round 474)
B-93    open, cost — the JS shim in two languages, UNDECIDED and no longer
        device-bound
```

## Canary

None — nothing was fixed. The variation this round has is the bar itself: a
literal written back into `fromMap` fails `policy_defaults_agree_test` naming the
field (`at location ['maxHeaders'] is <64> instead of <128>`), which round 453
demonstrated and this round did not re-run.

## Gate

Not re-run: no source changed. The last full gate, in round 470, was green.

## Not fixed

**B-93 itself**, and it needs a decision rather than a round. The two plugins
share no build system and no language, so "one copy" has to land somewhere, and
each candidate has a real cost: a Dart string passed down through `jsBootPrefix`
widens the package's surface; a bundled `.js` asset adds a loading path to two
native plugins on the one code path whose established failure mode is silence;
and a diff-check is the option the owner explicitly declined for this lead's Dart
half. All three are in B-93.

## Links

- RPC-15 — re-measure the loop's own record. Here the record was a STATUS: a lead
  marked `decided` whose decision was already carried out, with an undecided
  remainder attached
- L-13 — the decision inherits the sentence it was taken on; this is its
  bookkeeping twin, where the decision's SCOPE was the thing nobody re-read
- B-85 (closed), B-93 (filed), round 453 (did the work)
