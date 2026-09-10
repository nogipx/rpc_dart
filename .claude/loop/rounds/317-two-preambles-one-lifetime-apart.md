---
round: 317
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-25
bench: none
commit: yes
---

# Round 317 — two preambles, one lifetime apart

## Target

The second item round 315 left in `## Not fixed`: `RpcCallerContract` carries
what looks like the same preamble four times, minus the duplicate check, and
315 declined to merge because "whether a caller contract SHOULD refuse a
duplicate is a semantics question, not a tidy-up".

Taken now because it is the last named thread from the core sweep, and because
an unanswered "should we merge these?" is exactly the kind of item a later round
resolves by merging them.

## Hypothesis

Either the caller contract has the same exposure the responder had — a silent
replace that changes a call's shape — and needs the same rule, or the
resemblance is superficial and the merge would be wrong.

## Before

The responder's rule exists for a measured reason, recorded on
`_rejectDuplicate` itself: a repeated name silently replaced the earlier entry,
and "a contract declaring `m` as unary and then as a server stream answered a
unary call from the streaming handler, with nothing logged".

The question is whether `RpcCallerContract` can do that. One grep over the file
answers it:

```
_methods[...] =  writes        4, all in RpcResponderContract (lines 196-384)
                               0 after RpcCallerContract opens at line 410

RpcCallerContract fields       serviceName, dataTransferMode, _endpoint
                               no collection of any kind
```

## Mechanism

**It cannot, because it stores nothing.**

`RpcCallerContract` has `serviceName`, `dataTransferMode` and an
`RpcCallerEndpoint`. There is no `_methods`, no `_zeroCopyMethods`, no map of
any kind. Its four `call*` methods dispatch on the spot:

```dart
Future<TResponse> callUnary<TRequest, TResponse>({...}) {
  _validateCodecsForCodecMode(requestCodec, responseCodec);
  final (effectiveRequestCodec, effectiveResponseCodec) =
      _getEffectiveCodecs(requestCodec, responseCodec);
  return _endpoint.unaryRequest<TRequest, TResponse>(...);
}
```

A method name arriving twice is two CALLS. That is the normal case, not a
collision, and there is no earlier entry for a later one to replace.

**The resemblance is real and misleading.** Both sides resolve the
codec/zero-copy mode from `dataTransferMode` with the same two helpers, so the
code matches line for line. But the responder resolves it ONCE PER REGISTRATION,
to choose which of two maps the handler lands in; the caller resolves it ONCE
PER CALL, to decide what goes on the wire. Same computation, different lifetime,
different consequence.

Merging them would carry a registration rule onto a call path — dead at best,
and at worst refusing a second call to a method.

Worth noting that the genuinely shareable part is ALREADY shared:
`_RpcCodecMode` holds the mode logic for all three contract types, and its own
doc says it exists because the copies "had already drifted". What remains apart
is what differs.

## After

No code changed. Recorded as **C-34** so the merge is not attempted a third
time — 315 declined it on instinct, 317 has the reason.

## Canary

n/a — nothing changed. The control for the claim is structural and checkable in
one read: `RpcCallerContract` declares no collection field, so there is no state
for a duplicate to corrupt. If a later change gives it one, this negative is
void and `loop.py stale` will age it against the file it names.

## Gate

Not re-run: this round changed no code, only `.claude/loop/` records. The last
full gate, at round 315's commit `29acab93`, was analyze clean over 21 packages
plus wasm, `test:unit` 14 packages with 0 failures, format clean, licence
1317/1317.

## Not fixed

Nothing. Both threads round 315 opened are now closed — the zero-copy
asymmetry in 316 (cosmetic, B-32), the caller preamble here (must not merge,
C-34).

## Links

RPC-25 (`applied:` gains 317). C-34 (new).

This is the second CLEAN in a row and the pair is worth reading together: 316
found a defect that was not there, 317 found a duplication that must not be
merged. Both are the lens working in the direction it is least often credited
for — **declining**. RPC-25's own bar says the finding is the drift, and two
rounds in a row confirm what the bar is protecting against: a lens applied
without it turns into a licence to merge whatever looks alike.
