---
refines: U-21
paths: [.claude/loop/backlog/**, .claude/loop/checked/**, .claude/loop/lenses/**]
applies: the loop has more than a dozen rounds and records older than several of them
breaks: anything — a real defect hides behind a deferral; on this project that is how data loss was found.
applied: [201, 211, 232, 239, 247, 248, 249, 267, 278, 314]
status: confirmed (round 211)
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
