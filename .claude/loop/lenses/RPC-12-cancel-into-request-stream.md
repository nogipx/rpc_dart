---
refines: —
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**]
applies: cancellation is delivered into the handler's request stream
breaks: a process crash in user code that looks like a library bug.
applied: [202, 203, 204]
status: retracted (round 204)
---

# RPC-12 — Cancellation delivered into the handler's request stream

Do not mistake it for a defect again. See
`../rounds/204-retraction-listen-onerror.md` and rounds 202, 203 alongside it.

## Shape

Not a library defect but a contract: cancellation arrives as an error in the
request stream, and a subscription without `onError` makes it fatal to the
isolate.

## Detector

In examples and tests, `requests.listen(` with no `onError`.

## Ask

Is this library code or user code? Whose zone is the error in?

## Evidence

Two rounds spent on a defect that did not exist; the cause was in the probe's
own handler.
