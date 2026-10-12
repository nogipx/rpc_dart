---
round: 864
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-25
bench: P-331 — new
commit: yes
release: none
---

# Round 864 — a responder middleware refusal ends the stream there

## Target

Rounds 862-863 found a streaming response the responder could not send
skipped rather than ending the call. The same responder side has a second
way to fail one response locally: its own middleware throwing in
`processResponse`. RPC-25 across the shapes.

## Hypothesis

A response the responder's middleware rejects ends the call there on every
shape. Fails if a stream reads past it.

## Before

```
P-331:
         bad (ok1 rejected)        control
unary    ERROR 13                  OK ok1
server   ok0, ERROR 13             ok0, ok1, ok2, ok3, done
bidi     ok0, ERROR 13             ok0, ok1, ok2, ok3, done
```

## Mechanism

None found: the response middleware runs inside the handler's stream, so
its throw is the stream's error, which the pump answers before any later
item is sent.

## After

n/a.

## Canary

n/a — no fix. The control is the `control` arm, and round 862's
`ok0, ok2, ok3` shows the same kind of probe sees a skipped response.

## Gate

No library change.

## Siblings

—

## Not fixed

A middleware throwing in `processRequest` was not measured.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Bench
`../probes/P-331-a-responder-middleware-that-rejects-a-response.md`.
Negative `../checked/C-92-a-responder-middleware-refusal-ends-the-stream-there.md`.
Round `862-a-response-that-cannot-be-sent-ends-the-stream.md`.
