---
round: 239
verdict: CLEAN
packages: []
lens: RPC-15
bench: none — a migration, not a measurement
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks. The owner reviewed it live and caught two graph faults the round had not; both are fixed and filed as L-09
commit: yes
---

# Round 239 — finishing what 234 opened

## Target

**B-23, the top of `next`'s shortlist**, under RPC-15 — the lens for
re-measuring the loop's own record, which is what a migration of its own corpus
is. The lens key cannot be empty and naming an unrelated one would be worse.

**This is the first round where the script named the target without being
overridden.** Nothing was above it; the four lenses below it (RPC-20, RPC-21,
RPC-06, RPC-10) are all still there, untouched.

That the selector said so is the result of the previous work in this session:
leads used to sit last, reachable only once every lens was swept, so the loop
could not finish a thread by construction. Over rounds 234-238 it named a
never-applied lens five times running while this migration sat unfinished. Fixed
in two skill commits — `continuation: yes` as a tier, then a ranked shortlist
where the script ranks and the agent chooses.

## Hypothesis

Not a defect hunt. B-23's own claim is that pre-201 knowledge sits outside the
journal where nothing routes to or ages it, and the work is to move it.

## Before

The queue stood at 27 files. Six were closed this round, each by placing the
content, grepping its own numbers to prove it landed, and only then deleting:

```
  leak_audit_coverage              -> C-18   was a 4-line stub; now carries the
                                             2996-entry defect, the 38-case
                                             matrix, and why 600 CONCURRENT
                                             aborts reached only 34
  which_transport_uses_which_layer -> RPC-10  the layer map, and the round-197
                                             measurement that the policy half is
                                             unreachable on isolate at all
  web_dart2js                      -> RPC-07  the five dart2js bug classes C-25
                                             does not hold
  future_timeout_abandons_work     -> RPC-14  "adopt the abandoned future", the
                                             four-member family, one orphan per
                                             extra reconnect attempt
  client_stream_cancel...          -> already whole in rounds 202/203/204 and
                                             RPC-12; deleted with no top-up
  closed_transport_leniency        -> C-30   NEW: the leniency is a contract
                                             pinned by three tests, and a first
                                             fix attempt that added the throw
                                             failed all three
```

`backlog_proto_contract_generator` was reclassified rather than moved: it is a
feature the owner asked for, and features leave the loop by precedent (B-01).

## Mechanism

n/a — no defect. What this round did discover is about the corpus rather than
the code, and it cost the owner two interventions.

**The graph broke twice, invisibly.** Deleting notes left **19 dangling links
across 11 files** — the deletions look clean because a note's OUTBOUND links go
with it, while everything pointing AT it silently rots. Then rewriting the index
into prose that named the same files orphaned **10 notes** to zero inbound
edges. Both were found by the owner, not by the migration. Filed as
`../lessons/L-09-a-delete-has-an-inbound-half.md`, with the ten-line check that
found a fresh dangler on the very next deletion.

## After

```
  memory notes      41 -> 34, plus MEMORY.md
  B-23 queue        27 -> 21
  dangling links    19 -> 0
  orphaned notes    10 -> 0
  reachable from the index   13/34 -> 34/34
```

## Canary

n/a — no fix. The graph check IS the instrument, and its control is that it
fired on the next deletion after being written, catching
`closed_transport_error_type_split -> closed_transport_leniency_contract`
before that deletion was reported as clean.

## Gate

No package code changed; `git diff` over `packages/` is empty. `loop.py lint`
green.

## Not fixed

**B-23 stays open and keeps `continuation: yes`** — 21 files remain. Six are
per-subsystem dossiers that split into negatives and lens evidence the way the
earlier ones did; six are architecture description, which is the repo's docs'
job rather than the loop's and needs the owner's call on where they go.

**The private store still has no linter.** The check written this round lives in
a round record, not in a script anything runs. The repo half has `loop.py lint`;
the other half has the discipline in L-09 and nothing enforcing it.

## Links

Lead `../backlog/B-23-pre-201-knowledge-outside-the-journal.md` — still open,
queue narrowed, `continuation: yes` retained.
Lesson `../lessons/L-09-a-delete-has-an-inbound-half.md` — new.
Negative `../checked/C-30-closed-transport-leniency-is-a-contract.md` — new.
Round `238` — the last round before the selector could reach this lead at all.
