---
round: 865
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-25
bench: P-332 — new
commit: yes
release: none
---

# Round 865 — a caller middleware refusal ends the upload there

## Target

The request-side mirror of rounds 862-864: the caller's own middleware
rejecting one request of an upload. A skipped request would hand the
handler r0, r2, r3 as a complete upload. Round 641 measured a request the
caller cannot serialize; a middleware throw is a different path through
`caller_pipeline.dart`.

## Hypothesis

A request the caller's middleware rejects ends the upload there on both
upload shapes. Fails if the handler reads a request after it.

## Before

```
P-332:
         bad (r1 rejected)                           control
client   caller StateError; handler r0, cancelled    OK; handler r0..r3, DONE
bidi     caller StateError; handler r0, cancelled    OK; handler r0..r3, DONE
```

## Mechanism

None found: the middleware throw is an error of the request stream, which
the bridge answers by aborting the call and telling the server.

## After

n/a.

## Canary

n/a — no fix. The control is the `control` arm.

## Gate

No library change.

## Siblings

—

## Not fixed

—

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Bench
`../probes/P-332-a-caller-middleware-that-rejects-a-request.md`. Negative
`../checked/C-93-a-caller-middleware-refusal-ends-the-upload-there.md`.
Rounds `641-a-request-that-cannot-be-sent.md`,
`864-a-responder-middleware-refusal-ends-the-stream-there.md`.
