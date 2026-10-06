---
status: open
round: — (not re-measured)
commit: 81530a7b
paths: [packages/core/rpc_dart/lib/src/contracts/models.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart]
probe: .dart_tool/probe/codec_mode_response.dart
reason: owner decision — the documented contract and the code disagree, and which one is right is the owner's call
---

# B-250 — `auto` skips the codecs and the size limit, on unary only

Measured outside a round, by the transport parity matrix (`probe:` above), at the `commit:` sha.

On memory and isolate, with codecs passed and `transferMode` left at `auto`
(the default), a unary call over the limit goes through in both directions:

```
                      auto         codec
request 66560 B       OK           8
response 66560 B      OK           13 (B-249)
```

Server-stream items on the same transport are always serialized, so the same
66560-byte value fails there (B-249). One contract, one transport: unary passes,
streaming refuses.

The unary caller documents the choice (`unary/caller.dart:40`): `auto` keeps
the object path for speed (514 us against 807 us per round trip), and only an
explicit `codec` forces serialization. The enum says the opposite
(`models.dart:18`): "Auto mode — picks based on codec presence (codecs → codec
mode, otherwise zeroCopy)."

## Why it matters

With codecs written and the default mode, a field that `toJson` omits still
crosses to the isolate, and the message limit does not apply. The caller's own
comment names both effects. A user reading the enum expects neither.

## Options

- Fix the enum doc to match the code.
- Make `auto` mean codec mode when codecs are given, as the enum says.

Either way, decide whether streaming should follow unary.

## Owner decision

—
