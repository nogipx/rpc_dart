---
round: 202
verdict: RETRACTED
packages: [rpc_dart]
lens: RPC-12
bench: none
budget: probes 0/3, canaries 0/3
review: self (record migrated into the schema; the round itself had no review)
commit: no
---

# Round 202 — the claim that cancelling a clientStream kills the process

This record predates the schema: the bench, budget and review fields say "there
was none" rather than being reconstructed after the fact.

The bisect was compatible with the real cause the whole time: **a bisect tells
you who takes part, not who is at fault.**

## Target

RPC-12 — cancellation delivered into the handler's request stream

## Hypothesis

Cancelling a `clientStream` call kills the isolate

## Before

The process died on cancellation; the numbers were not kept

## Mechanism

A library defect was claimed; in fact the cause was in the probe's own handler —
`requests.listen((_) {})` with no `onError`

## After

n/a — the finding was retracted by round 204

## Canary

n/a

## Gate

n/a

## Not fixed

Nothing — there was nothing to fix

## Links

Retracted by round `204-retraction-listen-onerror.md`; the shape is recorded by
lens `../lenses/RPC-12-cancel-into-request-stream.md`
