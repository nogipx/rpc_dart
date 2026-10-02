---
round: 643
verdict: FIXED
packages: [rpc_dart]
lens: RPC-03
bench: none — the witness test is the measurement; the coverage-review probe is cov_endpoint_caller_token_key.dart
budget: probes 2/5, canaries 1/5
commit: yes
release: changelog
---

# Round 643 — a reused context

## Target

A coverage-review finding (round 640): the caller's cancellation registry,
`_callerTokens`, keyed by the context's requestId.

## Hypothesis

Every call in flight can be reached by `cancelMethod`, `cancelRequest` and
`close()`.

## Before

```
one RpcContext (an auth header) passed to two concurrent calls
pendingRequests 1 (2 in flight)   cancelMethod returned 1
B cancelled at 110 ms, A ran to completion at 2032 ms
```

## Control

A context per call: `pendingRequests 2`, `cancelMethod` 2, both cancelled at
109 ms.

## Mechanism

RPC-03's shape: an identifier taken as unique for a call when it is not. A
context reused across calls gives every call its requestId, so the second
call's token replaced the first's under the same key, and when either
finished its untrack removed the other's entry. The file's own comments treat
a reused context as supported.

## After

Keyed by the call's own context object, which `_prepareCallerContext` builds
fresh per call. `cancelRequest` cancels every call with that requestId.
`getCancellationTokensForMethod` keeps its type and documents that calls
sharing a requestId appear once; the new `activeCallCount` counts calls, and
the contract's `getActiveCallsCount` / `isMethodActive` use it.

## Canary

Re-adding "same requestId replaces the entry" at track time: `cancelMethod`
returns 1 for 2 calls.

## Gate

Recorded in round 645.

## Not fixed

Nothing known.

## Links

Lens `../lenses/RPC-03-stream-ids-restart-on-reconnect.md` — `applied: [..., 643]`.
Test `packages/core/rpc_dart/test/endpoint/a_reused_context_keeps_every_call_cancellable_test.dart`.
