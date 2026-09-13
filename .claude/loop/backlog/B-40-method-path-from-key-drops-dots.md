---
status: open
round: 360
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

None required. This is a bar judgement, not a trade: if the bar drops, or if a
round touches `_methodPathFromKey` anyway, apply the four-line fix above with a
unit test on the function. Recorded so the next reader does not re-derive that
the happy path is fine.
