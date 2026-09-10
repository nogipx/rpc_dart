---
round: 315
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none
commit: yes
---

# Round 315 — eight places for one rule

## Target

The owner's question: refactor the responders and contracts in core. RPC-25 has
been applied to transports (308, 310-312) and servers (309) and **never to
core** — so this is new ground rather than a re-tread.

## Hypothesis

`RpcResponderContract` exposes four registration methods —
`addUnaryMethod`, `addServerStreamMethod`, `addClientStreamMethod`,
`addBidirectionalMethod`. Four siblings written to one shape is exactly what
step 1 looks for.

## Before

Step 1, run rather than reasoned. All four open with the identical preamble:

```dart
_validateCodecsForCodecMode(requestCodec, responseCodec);
final (effectiveRequestCodec, effectiveResponseCodec) =
    _getEffectiveCodecs(requestCodec, responseCodec);
final isZeroCopy =
    effectiveRequestCodec == null && effectiveResponseCodec == null;
```

and then call `_rejectDuplicate(methodName)` **inside each of the two
branches**:

```
_rejectDuplicate call sites   8   (4 methods x 2 branches)
identical preamble            4
```

## Mechanism

Eight call sites for a rule that has nothing to do with the branch. Whether a
name is already taken does not depend on whether this registration would be
zero-copy or serialized — the check reads BOTH maps, which is precisely why it
cannot depend on the mode.

Placed inside the branches, the rule is one edit away from being enforced on
three paths out of four, and the analyzer would say nothing. `_rejectDuplicate`
itself carries the reason it exists: a repeated name used to silently replace
the earlier entry, and "different shapes is dangerous, because the shape changes
with it — a contract declaring `m` as unary and then as a server stream answered
a unary call from the streaming handler, with nothing logged."

`_prepareRegistration` now answers the three questions once — validate, refuse a
duplicate, resolve the codecs — and each method reads the returned codecs as its
branch condition.

**The ordering moved and the behaviour did not.** `_validateCodecsForCodecMode`
still runs FIRST, so a call that is both a duplicate and codec-invalid still
reports the codec error, as before. What changed is that `_getEffectiveCodecs`
no longer runs for a name about to be rejected — work skipped, nothing observed.

**No drift found**, and that is reported rather than omitted: the four preambles
were byte-identical, and `_rejectDuplicate`'s eight call sites were all the same
call. This is a duplication finding, not a divergence one — the second kind
RPC-25 admits, where the risk is what the NEXT edit does rather than what the
current code does.

## After

```
_rejectDuplicate call sites   8 -> 1
identical preamble            4 -> 1
```

## Canary

`duplicate_method_registration_test.dart` already exists and covers what moved:
same shape twice, different shapes, codec-vs-zero-copy across the two maps, and
that the failure names the method. It exercises both `addUnaryMethod` and
`addServerStreamMethod`, and both maps — so the rule is witnessed on the
serialized path, the zero-copy path, and the cross-map case.

That is the honest strength of it: the test predates this round and passes
unchanged, which is what "behaviour-preserving" has to mean. It is not a witness
that the extraction was NEEDED — nothing can be, for a duplication finding with
no drift.

Core suite: 1433 passed, 1 skipped, 0 failed.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, 0 failures.
`melos run format:check` — SUCCESS after formatting `contract.dart`, which the
gate caught.
`melos run license:check` — compliant, 1317/1317.

## Not fixed

Two things this round measured and deliberately left, both in the same file:

- **The caller-side contract has the same preamble four times**, minus the
  duplicate check (`contract.dart` around lines 490-590, a different class with
  its own `_getEffectiveCodecs`). It is the same shape, but the missing
  `_rejectDuplicate` is the interesting part — whether a caller contract SHOULD
  refuse a duplicate is a semantics question, not a tidy-up, so merging the two
  preambles would quietly answer it. Left for a round that asks it directly.
- **The zero-copy registration is typed asymmetrically.** Unary and server-stream
  register `RpcZeroCopyMethodRegistration<TRequest, TResponse>`; client-stream
  and bidirectional erase to `<Object, Object>` and cast inside an
  `adaptedHandler`. The registry stores `<Object, Object>`, so the first pair
  relies on Dart's covariance and an implicit runtime check where the second
  pair casts explicitly. **This is a real asymmetry and it was not touched**,
  because deciding which form is correct needs the registry's dispatch read end
  to end, which is a round of its own.

## Links

RPC-25 (`applied:` gains 315). First application to core.

What core adds to the lens: a duplication with NO drift can still be worth
merging when the duplicated thing is a RULE rather than a computation. Eight
copies of "is this name taken" are eight chances to answer it differently later;
that is a different argument from the line count RPC-25 otherwise declines, and
it is the one that justified this round where `_notify` and `RpcMessageParser`
were declined.
