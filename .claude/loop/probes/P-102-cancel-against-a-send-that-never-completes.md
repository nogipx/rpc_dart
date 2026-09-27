---
file: packages/core/rpc_dart/.dart_tool/probe/cancel_with_a_hanging_notice.dart
round: 448
commit: ade982bc
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
status: valid
---

# P-102 — cancel against a send that never completes

## Why it exists

Two sites send a cancellation notice and tear down in opposite orders, each with
a comment defending itself. The variable is therefore not the code but the
TRANSPORT: the sibling's comment names the class that hangs, so the bench has to
supply one.

## The harness

`RpcChannelTransport.pair()` wrapped in a decorator whose `sendMetadata` returns
a never-completing `Future` when `endStream` is true — the exact shape a
cancellation notice takes. Everything else delegates.

**The wrapper must NOT implement `IRpcStreamReset`.** `_notifyPeerOfCancellation`
tries a stream reset first and returns on success, so a wrapper claiming that
capability never reaches `sendMetadata` and the arm is void.

A handler that never answers, so the call is still in flight when the token is
cancelled. The reading is whether the CALL's future settles within 3 s, reported
as the string `hung` — so a hang is an assertable value and not a test that dies
on a timeout.

## The numbers (round 448)

```
                          before fix              after fix
unary,  hanging notice    NEVER SETTLED (hung)    RpcCancelledException
unary,  normal notice     RpcCancelledException   RpcCancelledException
stream, hanging notice    RpcCancelledException   RpcCancelledException
stream, normal notice     RpcCancelledException   RpcCancelledException
```

## Measures

Whether the in-flight call's future settles after `token.cancel()`, and with
what. Not `cancel()` itself, which is what the lead expected: the `await` sits in
the call's own `finally`, so it is the CALL that never returns.

## Control

Two, and the second is the one that makes this about ordering.

1. **The same path, notice completing normally** — settles. So the hang is the
   hanging send and not the harness.
2. **The SIBLING ordering against the same hanging transport** — the streaming
   shape sends the notice `unawaited` and settles. Identical transport, opposite
   outcome, which is exactly the claim the two comments were arguing about.

After the fix all four rows read the same, so the table no longer distinguishes;
the canary is what carries the evidence from then on.

## What it establishes, and what it does not

Establishes: awaiting the notice inside the call's teardown converts a stalled
network write into a caller that never learns its call was cancelled.

Does not establish that any SHIPPING transport hangs this way. The wrapper is
constructed for the purpose. What the comment in `base_processor` asserts — that
a transport whose send awaits a platform reply can do this — is still an
assertion; this bench shows only what happens IF one does.
