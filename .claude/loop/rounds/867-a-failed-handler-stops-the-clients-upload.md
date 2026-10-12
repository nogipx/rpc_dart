---
round: 867
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-25
bench: P-333 — new
commit: yes
release: none
---

# Round 867 — a failed handler stops the client's upload

## Target

Round 861's mirror (I-6): the server's handler fails while the client is
still uploading. If the caller kept pulling its request producer after the
server's error trailer, an endless upload would run into a dead call.

## Hypothesis

Once the server ends an upload call, the caller stops pulling its request
producer. Fails if the producer keeps being pulled.

## Before

```
P-333, producer yielding every 10 ms forever; pulls in the 1 s after the call ended:
arm      client-stream          bidi
throw    ERROR 10, 1 more       ERROR 10, 1 more
control  OK two, 1 more         OK [two], 1 more
reads    HUNG, 75 more          (contaminated by the client-stream producer)
```

## Mechanism

None found: both callers cancel the request subscription when the
response side ends.

## After

n/a.

## Canary

n/a — no fix. The `reads` arm is the control.

## Gate

No library change.

## Siblings

—

## Not fixed

—

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Bench
`../probes/P-333-does-a-failed-handler-stop-the-upload.md`. Negative
`../checked/C-95-a-failed-handler-stops-the-clients-upload.md`. Round
`861-a-bidi-call-that-fails-locally-tells-the-server.md`.
