---
round: 659
verdict: FIXED
packages: [rpc_dart]
lens: RPC-04
bench: none — the witness test is the measurement; reviewer probes peer_middleware_context.dart, peer_responder_icpt_context.dart
budget: probes 2/5, canaries 2/5
commit: yes
release: changelog
---

# Round 659 — an interceptor with its own token

## Target

The peer and middleware review: an interceptor that passes `next` a context
with a new cancellation token.

## Hypothesis

Every cancel the endpoint tracks still reaches the call.

## Before

```
caller interceptor swaps the token
  pendingRequests before cancelAllMethods: 1
  cancelAllMethods(): no result for the call at all; after 1.5 s
  caller {pending 0, transport activeStreams 1}, server {open 1, active 1}
responder interceptor swaps the token
  caller cancels at 80 ms; handler token NOT cancelled after 2 s, while the
  server already reports open 0 active 0
```

## Control

The same interceptor passing the context through: the caller gets
`RpcCancelledException: user cancel`, the handler's token fires, everything 0.

## Mechanism

RPC-04, a capability lost through a wrapper. The endpoint tracks the token a
call STARTED with -- the caller's registry, the responder's stream state for a
client cancel, a deadline, a drain -- and an interceptor's context replaced it
for everything below. Nothing linked the two, so the call ran on a token no
tracked cancel could reach; on the caller the call hung untracked.

## After

The interceptor chain links them at the handler, for every shape on both
sides: cancelling the original token cancels the interceptor's; a context
with no token gets the original back. One way only -- the interceptor's own
token stays its own to fire. Both arms read as the control.

## Canary

The link disabled: the caller arm reads `HUNG`, the responder arm times out.

## Gate

Rounds 658-659 together: `analyze` (21 packages and wasm) green, `format`
clean. `test:unit`: every package green except rpc_dart, four reds in
`a_failed_registration_leaves_nothing_behind_test` -- it built its
"second failure route" from a dotted method colliding with another service's
key, the collision round 658 makes impossible. Reworked to reach the same
all-or-nothing path through a refused second method name; rpc_dart rerun
alone, 2048 passed. `test:web`: the first run failed on round 655's
`exponential_backoff_bounds_test`, whose own `1 << 40` is 0 on the web
(32-bit shifts) -- the library clamps the exponent before shifting and was
right; the test now uses a literal. Rerun green, exit 0, all 14 suites.

## Not fixed

The link holds a listener on the original token's future until it fires: with
a long-lived token reused for many calls through such an interceptor, one per
call. Owner questions from the review: whether a deadline set by a RESPONDER
interceptor should be enforced (it is not), and whether middleware on a peer
should be able to tell an outgoing call from an incoming one.

## Links

Lens `../lenses/RPC-04-capability-hidden-by-wrapper.md` — `applied: [..., 659]`.
Test `packages/core/rpc_dart/test/endpoint/an_interceptor_token_is_still_cancelled_test.dart`.
Leads filed from the same reviews: `../backlog/B-242-honest-metadata-closes-the-server-connection.md`,
`../backlog/B-243-stream-ids-collide-across-reconnects-after-a-wrap.md`.
