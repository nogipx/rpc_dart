---
round: 317
commit: 77715121
scope: "whether `RpcCallerContract` needs the duplicate-name rule `RpcResponderContract` has, and whether their two identical-looking preambles should be merged"
paths: [packages/core/rpc_dart/lib/src/contracts/contract.dart]
---

# C-34 — the caller contract has nothing to duplicate

Round 315 extracted `_prepareRegistration` on `RpcResponderContract` and left an
open item: `RpcCallerContract` has what looks like the same preamble four times,
minus the duplicate check, and "whether a caller contract SHOULD refuse a
duplicate is a semantics question, not a tidy-up".

**Checked in round 317. It should not, and the two preambles must not be
merged.**

## Why

`RpcCallerContract` holds no registration map. It has `serviceName`,
`dataTransferMode` and an `RpcCallerEndpoint`, and its four `call*` methods
DISPATCH rather than register:

```dart
Future<TResponse> callUnary<TRequest, TResponse>({...}) {
  _validateCodecsForCodecMode(requestCodec, responseCodec);
  final (effectiveRequestCodec, effectiveResponseCodec) =
      _getEffectiveCodecs(requestCodec, responseCodec);
  return _endpoint.unaryRequest<TRequest, TResponse>(...);   // <- goes out now
}
```

There is no `_methods`, no `_zeroCopyMethods`, and nothing stored between calls.
A method name arriving twice is two CALLS, which is the normal case.

## What the resemblance actually is

Both sides resolve the codec/zero-copy mode from `dataTransferMode`, and both do
it with the same two helpers — which is why the preambles read alike. But the
responder resolves it ONCE PER REGISTRATION, to decide which of two maps the
handler goes in; the caller resolves it ONCE PER CALL, to decide what to put on
the wire. Same computation, different lifetime, different consequence.

`_rejectDuplicate` belongs to the registration lifetime only. Merging the
preambles would carry a registration rule onto a call path, where at best it is
dead and at worst it refuses a second call to the same method.

## Control

The negative is structural, so the control is the class that DOES have the
exposure, read the same way.

    RpcResponderContract    _methods, _zeroCopyMethods   -> state between calls,
                                                            so a repeat replaces
    RpcCallerContract       (no collection field at all) -> nothing to replace

Same grep over both classes:
`grep -n "^abstract class\|_methods\[" contract.dart` returns four
`_methods[...] =` writes, all inside `RpcResponderContract` (lines 196-384) and
none after `RpcCallerContract` opens at 410.

That is what makes this a negative rather than an absence of evidence: the check
distinguishes the two classes, and it would have found the writes if they were
there. If a later change gives the caller a collection field, this negative is
void — `loop.py stale` ages it against the file it names.

## The trap this closes

The merge is attractive precisely because the visible code matches. Round 315
declined it on instinct — "merging the two preambles would quietly answer it" —
and this is the answer, so the next round does not re-open it and does not
perform the merge.

Note that both classes already delegate the shared part to `_RpcCodecMode`,
whose own doc says it exists "so the three contract types delegate to it instead
of each copy-pasting the logic (which had already drifted)". The genuinely
shareable part is shared; what remains apart is what differs.
