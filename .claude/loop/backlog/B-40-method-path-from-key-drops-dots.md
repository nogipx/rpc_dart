---
status: closed (round 420)
round: 420
commit: 7a3c66d5
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/three_core_diagnostics.dart
reason: "below the severity bar and unwitnessed: the damage is a wrong string in a context nobody reads back, on a path only a hostile peer reaches, and round 360 could not build a witness that reaches it"
---

# B-40 — `_methodPathFromKey` cannot round-trip a dotted service name

## What the code does

```dart
String _methodPathFromKey(String methodKey) {
  final parts = methodKey.split('.');
  if (parts.length != 2) return '/UnknownService/UnknownMethod';
  return '/${parts[0]}/${parts[1]}';
}
```

A method key is `'$serviceName.$methodName'`. For
`myapp.v1.UserService.Get` the split yields four parts, so the method returns
`/UnknownService/UnknownMethod` — the real name discarded.

**The library's own inbound parser explicitly admits those names.**
`_parseMethodPath` validates each segment against `[A-Za-z0-9_.-]+`, dots
included, which is also what gRPC uses for fully-qualified protobuf services
(`google.protobuf.Empty`). So one half of the pair accepts what the other cannot
express — U-14, the sibling comparison, inside one file.

## Why it is a lead and not a fix

**Measured: the ordinary path is CLEAN.** A dotted service name round-trips
through a real call — `myapp.v1.UserService` and `google.protobuf.Empty` both
answered `ok`. `methodPath` travels on the frame, and `_ensureResponderContext`
only falls back to `_methodPathFromKey` when BOTH `metadataMessage` and
`lastPayloadMessage` are null while `methodKey` is set.

Reaching that state needs a peer that sends a payload frame carrying a method
path, has its metadata frame never retained, and then has the retained payload
taken by `takeLastPayload()` before the context is built. Round 360 did not
build a witness for it and does not claim it is impossible — only that it was
not reached.

And the damage, when reached, is a wrong `methodPath` STRING inside an
`RpcContext` on an error path. Nothing routes on it; it is diagnostic. Against
the config's bar — data loss, a crash, a hang, a security hole, an unbounded
leak — it does not qualify.

## The fix, if it is ever taken

Split on the LAST dot, mirroring how the key is built:

```dart
final i = methodKey.lastIndexOf('.');
if (i <= 0 || i == methodKey.length - 1) {
  return '/UnknownService/UnknownMethod';
}
return '/${methodKey.substring(0, i)}/${methodKey.substring(i + 1)}';
```

A method name cannot contain a dot — it is a Dart identifier at the contract —
so the last dot is unambiguous. Worth doing in any round that touches this
method for another reason; not worth a round of its own.

## Owner decision

~~None required.~~ **Taken in the backlog review: apply it now.**

The bar argument was about whether to go LOOKING for this, and it is sound — the
damage is a wrong diagnostic string nothing routes on, reached only by a hostile
peer. But the finding is already paid for and the fix is four lines that were
written out two hundred rounds ago. Holding it until some round happens to touch
`_methodPathFromKey` costs more in re-reading than in applying.

Split on the LAST dot: a method name cannot contain one. Unit test on the
function directly, with `myapp.v1.UserService.Get` as the case that fails today,
and the single-dot form as the control that must keep working.

The happy path stays measured-clean and does not need re-establishing: dotted
names round-trip because `methodPath` rides on the frame, and the formatter is
consulted only when both retained messages are null while `methodKey` is set.

## Closed — round 420

Split on the LAST dot, and the function MOVED: `rpcMethodPathFromKey` now lives
in `metadata.dart` beside `parseRpcMethodPath`, which is its inverse.

**Moving it was the fix, not a tidy-up.** The first witness reimplemented the
rule and checked itself — it would have passed with the production code
reverted — because the formatter was private on a mixin RPC-24 hides from the
public surface. The test now asserts the PROPERTY against both real functions:
the formatter rebuilds everything the parser admits.

An inverse pair that cannot be read together is an inverse pair that drifts.

Still not driven end to end: the formatter is reached only when both retained
messages are null and `methodKey` is set, which is why this stood for two
hundred rounds.
