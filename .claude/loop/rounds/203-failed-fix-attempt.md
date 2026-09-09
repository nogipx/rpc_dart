---
round: 203
verdict: INCONCLUSIVE
packages: [rpc_dart]
lens: RPC-12
bench: none
budget: probes 0/3, canaries 0/3
review: self (record migrated into the schema; the round itself had no review)
commit: no
---

# Round 203 — an attempt to fix a defect that did not exist

INCONCLUSIVE, not CLEAN: the round measured nothing and therefore proved
nothing. This outcome is exactly the price of working from reasoning instead of
measurement — the next round started by instrumenting and closed the question in
one pass.

The four disproven theories are listed in round 204's record so nobody tries
them again.

## Target

RPC-12 — cancellation delivered into the handler's request stream

## Hypothesis

The crash claimed by round 202 is fixed by one of four edits

## Before

n/a — the round took no measurements, it worked from reasoning

## Mechanism

Four theories in a row, none confirmed; every edit reverted, the tree left
byte-for-byte unchanged

## After

n/a

## Canary

n/a — no failing witness could be produced

## Gate

n/a

## Not fixed

Nothing; the defect did not exist, as round 204 showed

## Links

Revised by round `204-retraction-listen-onerror.md`; the shape is
`../lenses/RPC-12-cancel-into-request-stream.md`
