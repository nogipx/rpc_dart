---
round: 316
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-25
bench: none
commit: yes
---

# Round 316 — a convincing argument that was wrong

## Target

The thread round 315 left open: the zero-copy registrations are typed two ways,
and 315 said deciding which is correct "needs the registry's dispatch read end
to end, which is a round of its own". This is that round.

## Hypothesis

One of the two shapes is wrong. Either the erasure in the stream forms is
redundant, or the real types in the unary/server-stream forms break dispatch.

## Before

```
addUnaryMethod        RpcZeroCopyMethodRegistration<TRequest, TResponse>
addServerStreamMethod RpcZeroCopyMethodRegistration<TRequest, TResponse>
addClientStreamMethod RpcZeroCopyMethodRegistration<Object, Object> + adapter
addBidirectionalMethod RpcZeroCopyMethodRegistration<Object, Object> + adapter
```

The dispatch path, read: `RpcResponderMethodBinding.zeroCopyRegistration` is
declared `RpcZeroCopyMethodRegistration<Object, Object>`, and
`models.dart:72` casts the stored handler to
`Future<TResponse> Function(TRequest, {RpcContext? context})`.

## Mechanism

**The reading produced a defect, and the defect was not there.**

With `TRequest`/`TResponse` taken as `Object`, the cast reads
`Future<Object> Function(Object, ...)`, and Dart function subtyping is
contravariant in parameters — so a stored
`Future<MyRes> Function(MyReq, ...)` is not a subtype and the `as` should throw.
That would make zero-copy unary and server-stream broken outright.

It is wrong because **Dart generics are reified.** The static upcast to
`<Object, Object>` does not change the instance's runtime type arguments;
`callUnaryHandler` on a registration constructed as `<ZcReq, ZcRes>` runs with
`TRequest = ZcReq`, and the cast is an identity. The contravariance argument was
applied to the static type at the call site while the check happens against the
reified type of the receiver.

**One grep settled it.**
`rpc_dart_isolate/test/unsendable_direct_object_test.dart:120` registers
`addUnaryMethod<ZcReq, ZcRes>` with no codecs — zero-copy unary with specific
types, exactly the shape predicted to throw — on the one transport where
`supportsZeroCopy` is true. It passes, and has been passing.

## After

No code changed. The asymmetry is **cosmetic**: the erasure plus
`requests.cast<TRequest>()` in the stream forms is redundant against the reified
type rather than a correctness measure. Unifying the four shapes is a no-drift
duplication with no rule attached, which RPC-25 declines on its own terms.

Filed as **B-32**, closed on the alarming half and left open only on the
cosmetic one — so the asymmetry is not investigated a third time.

## Canary

n/a — nothing was changed. The control for the claim is the existing test that
exercises the predicted-failing shape, and the fact that it is green is the
measurement.

## Gate

Not re-run: this round changed no code, only `.claude/loop/` records. The last
full gate, at round 315's commit `29acab93`, was analyze clean over 21 packages
plus wasm, `test:unit` 14 packages with 0 failures, format clean, licence
1317/1317.

## Not fixed

Nothing found to fix. That is the result, not a shortfall.

## Links

RPC-25 — the asymmetry it surfaced in 315 is resolved as a non-finding. B-32.

**The lesson, and it is the fourth time in eight rounds.** 309 said logs were
untestable; 312 said the same of a contract and of dead code; 313 corrected two
of those; and 316 asserted a defect from type reasoning. Every one was *a
conclusion reached by reading, where a grep or a probe was cheap and available*.
The direction of the error does not matter — optimistic or alarmist, the fix is
the same: run the check first. It cost one command here.

Not filed as `L-N`: the price was one round's reasoning, not a measured cost,
and `lessons/` requires a number.
