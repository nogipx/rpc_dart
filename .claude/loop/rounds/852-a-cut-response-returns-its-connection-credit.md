---
round: 852
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-01
bench: P-319 — new
commit: yes
release: none
---

# Round 852 — a cut response returns its connection credit

## Target

RPC-01, second in rank and last applied in round 825, asks whether every
path that drops bytes gives their flow-control credit back. Round 846 added
one: a response cut mid-frame ends INTERNAL with its partial frame left in
the caller's parser. If those bytes were never credited, a server repeating
it would drain the connection window and stall every call on it.

## Hypothesis

The caller credits a cut response's bytes back to the connection window as
it does a whole one. Fails if the grants fall short of the bytes received.

## Before

```
arm                 received    granted     short
whole x10           600210 B    802333 B    -202123 B   (control)
cut x10             590100 B    793234 B    -203134 B
whole x10, ablated  600210 B    262144 B    +338066 B   (_creditConnection off)
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/r852_credit_after_cut_responses.dart`.

A first ablation, `onConsumed` crediting nothing, moved nothing: this path
credits through the per-stream controller and teardown, not `onConsumed`.
The second, aimed at `_creditConnection`, showed the bench sees a shortfall.

## Mechanism

None found: the transport counts the DATA message as consumed when the
caller processor takes it, before its parser decides the frame is partial.

## After

n/a.

## Canary

n/a — no fix. The ablated row is the bench's control.

## Gate

No library change; both ablations reverted (`git status` clean).

## Siblings

—

## Not fixed

Round 847's responder refusal (a unary request with trailing bytes) was not
measured here; it refuses the call before the handler and tears the stream
down, the path round 825 measured for decode refusals.

## Links

Lens `../lenses/RPC-01-flow-control-credit-on-skip.md`. Bench
`../probes/P-319-connection-credit-after-cut-responses.md`. Negative
`../checked/C-87-a-cut-response-returns-its-connection-credit.md`. Round
`846-a-response-cut-mid-message-is-an-error.md`.
