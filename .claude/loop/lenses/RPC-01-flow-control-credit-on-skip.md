---
refines: U-07
paths: [packages/core/rpc_dart/lib/**]
applies: there is credit accounting released on message delivery
breaks: a wedged connection — a hang.
applied: []
status: confirmed (round 162, off-journal)
---

# RPC-01 — Flow-control credit on the skip path

## Shape

A frame is refused or skipped without becoming a message, while the credit
return hangs on the "message delivered" event.

## Detector

`_fcOnConsumed` and every one of its callers; every place a frame is dropped
before it becomes a message; `sendMessage` as the sole consumer of credit.

## Ask

Will the credit the sender has already charged itself ever come back?

## Evidence

An 8 MiB window with 2 MiB per refusal: it wedged on exactly the fourth refusal.
Metadata frames are outside flow control — checked, not assumed.
