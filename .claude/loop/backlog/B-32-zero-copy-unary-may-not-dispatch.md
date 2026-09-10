---
status: open
round: 316
commit: 29acab93
paths: [packages/core/rpc_dart/lib/src/contracts/models.dart, packages/core/rpc_dart/lib/src/contracts/contract.dart, packages/core/rpc_dart/lib/src/endpoint/responder_registry.dart]
probe: none
reason: "answered in the round that filed it — the reading was wrong, and the existing suite already covers the shape it predicted would throw"
---

# B-32 — zero-copy unary may not dispatch at all — WRONG, closed

**Filed and closed in round 316.** Kept rather than removed, because the
reasoning is the kind that looks convincing and is not, and the next reader of
round 315's open question deserves the answer rather than the trap.

## What was claimed

Round 315 recorded that the four `add*Method` registrations type their zero-copy
entry two ways: unary and server-stream with the user's real
`<TRequest, TResponse>`, the two stream forms erased to `<Object, Object>` with
an adapting handler.

Reading the dispatch, `RpcResponderMethodBinding.zeroCopyRegistration` is typed
`RpcZeroCopyMethodRegistration<Object, Object>`, and `models.dart:72` casts:

```dart
handler as Future<TResponse> Function(TRequest, {RpcContext? context});
```

The claim: with both parameters bound to `Object`, that is
`Future<Object> Function(Object, ...)`, and since Dart function subtyping is
**contravariant in parameters**, a stored
`Future<MyRes> Function(MyReq, ...)` is not a subtype of it — so the cast should
throw and zero-copy unary should be broken.

## Why it is wrong

**Dart generics are reified.** The static upcast to
`RpcZeroCopyMethodRegistration<Object, Object>` does not change the INSTANCE's
runtime type arguments. When `callUnaryHandler` runs on a registration built as
`RpcZeroCopyMethodRegistration<ZcReq, ZcRes>`, its `TRequest` and `TResponse`
are `ZcReq` and `ZcRes` at runtime — not `Object` — so the cast is an identity
and succeeds.

The contravariance argument was applied to the STATIC type at the call site
while the check happens against the REIFIED type of the receiver.

## The evidence that should have come first

`packages/transport/rpc_dart_isolate/test/unsendable_direct_object_test.dart:120`
registers `addUnaryMethod<ZcReq, ZcRes>` with no codecs — zero-copy unary with
specific types, exactly the shape predicted to throw — and it passes, on the one
transport where `supportsZeroCopy` is true.

One grep of the test directory answered what a page of type reasoning did not.

## What this leaves

The asymmetry round 315 recorded is **cosmetic**: the erasure plus
`requests.cast<TRequest>()` in the two stream forms is redundant against the
reified type, not a correctness difference. Unifying the four is still tidier —
one shape rather than two for the same job — but it is a no-drift duplication
with no rule attached, which RPC-25 declines. Not worth a round.

## The lesson, which is the reason this file stayed

Rounds 309, 312 and 313 each asserted something was untestable or inapplicable
and were wrong; this one asserted a defect from types and was wrong in the other
direction. Same failure mode: **a conclusion reached by reading, where a grep or
a probe was available and cheap.** The check here cost one command.

## What is left open

Only the cosmetic unification: make all four zero-copy registrations use one
shape instead of two. It is a no-drift duplication with no rule attached, which
RPC-25 declines on its own terms, so it is filed rather than done — and filed
mainly so the asymmetry is not re-investigated a third time.

## Owner decision

—
