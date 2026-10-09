---
round: 690
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: none — a new test with an in-test CONNECT proxy, `packages/transport/rpc_dart_http2/test/goaway_through_a_proxy_test.dart`
commit: yes
release: changelog
severity: S2
---

# Round 690 — GOAWAY through a proxy

## Target

B-177: both `_guardedConnection(...)` calls in `_connectH2ViaProxy` omit
`drainSignal:`, so over a proxy `goawayReceived` stays false.

## Hypothesis

A connection draining after GOAWAY is then reported as the stream ceiling
(RESOURCE_EXHAUSTED) instead of UNAVAILABLE, and `health()` says healthy.

## Before

The first version of the witness passed: with nothing in flight, the server's
`finish()` closes the connection at once and the caller reads a closed socket,
which is UNAVAILABLE either way. The lead's case needs the connection to stay
open, draining -- so the witness holds one call in flight across GOAWAY, then
makes another, through the proxy:

```
a call after GOAWAY is UNAVAILABLE     Expected: <14>  Actual: <8>
health stops reporting healthy         Expected: not healthy  Actual: healthy
```

## Mechanism

As hypothesised: the direct paths pass the transport's `_DrainSignal` to the
connection guard, which sets `goawayReceived`; the proxy path built its
connection without it, so the transport's own signal never flipped.

## Fix

`_connectH2ViaProxy` takes `drainSignal` and passes it to both of its
`_guardedConnection` calls (TLS and plaintext); both callers hand it theirs.

## After

2 of 2 green. Full `rpc_dart_http2` suite: 286 passed.

## Canary

Before is the canary: the same test without the parameter. The first,
nothing-in-flight version is the control: it passed both ways, which is why
the draining case had to be built.

## The verdict questions

1. Yes: Before is the canary; the closed-at-once case the control.
2. Yes: the status and the health the lead named.
3. Yes: the caller's status and `health()`.
4. Not zero-valued.
5. Yes, quoted.
6. One cause.
7. Not a policy question.
8. None.

## Gate

`analyze`, `format:check`, the `rpc_dart_http2` suite.

## Not fixed

Only the plaintext tunnel was measured; the TLS branch takes the same
parameter in the same way.

## Links

Lead `../backlog/B-177-http2-goaway-is-invisible-through-a-proxy.md` closed.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` -- `applied: [..., 690]`.
