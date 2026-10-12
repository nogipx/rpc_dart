---
round: 849
commit: 362a89a8
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/lib/src/rpc/streams/**, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
scope: the caller's own deadline on all four shapes over the channel pair, the context's clock jumped one hour back or forward 200 ms into a 1 s deadline; not the responder (its clock is DateTime.now and cannot be moved here)
---

# C-84 — a call deadline holds through a clock jump

A caller's deadline ends the call on time whatever its context's clock does
afterwards: unary, server, client and bidi all ended at about 1 s with
DEADLINE_EXCEEDED after the clock jumped an hour back, and the server stream
the same after a jump forward. The timers that enforce it are armed from
`remainingTime` at the start and run on the monotonic clock; nothing on the
path re-reads the wall clock. Bench `../probes/P-318-a-wall-clock-jump-during-a-call.md`.

## Control

The same bench showed it can see a clock dependency where one exists:
`RpcRetryInterceptor`'s reconnect wait, which re-reads the context's clock,
ran 5112 ms on the same jump (round 849).
