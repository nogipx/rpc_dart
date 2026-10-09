---
status: closed (round 543)
round: 541
commit: aeebbbfb
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/test/core/compression_never_makes_a_message_bigger_test.dart, pubspec.yaml]
probe: P-175
release: breaking
reason: "closed by round 543, which found this lead's own diagnosis wrong: the six failures were a library defect, not a bad test"
---

# B-211 — `test:web` has been red since round 513

Filed in round 541 after running the web target following a core change. Closed in round 543.

```
melos run test:web   +1764 ~1 -6
```

All six failures in
`packages/core/rpc_dart/test/core/compression_never_makes_a_message_bigger_test.dart`:

```
RpcStatusException(12): Unsupported grpc-encoding: gzip. Supported: identity.
On web/dart2js the built-in gzip is unavailable; register a cross-platform codec
(e.g. RpcGzipCodec.register() from package:rpc_dart_compression).
```

## This lead's diagnosis was WRONG, and the way it was wrong is the point

It said: *"The library is behaving correctly. The message is the library's own, it names the
remedy... What is wrong is the TEST."*

That was inferred from the error STRING and from nothing else. Nothing was varied. The message
is accurate about gzip's availability on dart2js and says nothing about the question that
mattered — whether the caller announces gzip anyway.

**It does.** `caller_pipeline` set `grpc-encoding: gzip` from a constant, six lines above a
block that built `grpc-accept-encoding` from the registry. So wherever no gzip codec is
registered the caller declared an encoding it could not perform, the peer refused it, and
**every call failed** — making `compressionEnabled: true` unusable on the web. One
`unregister('gzip')` call on the VM shows it in a second:

```
  registry                         compressionEnabled: true
  as shipped (identity,gzip)       echoed 64 bytes
  gzip UNREGISTERED (identity)     RpcStatusException(12): Unsupported grpc-encoding: gzip
  a registered codec               echoed 64 bytes
  CONTROL compression off          echoed 64 bytes
```

Rule one, exactly: prose about code is a secondary source, and an error string is prose. The
lead quoted it as evidence.

## Outcome (round 543) — three causes, one defect

`../rounds/543-the-encoding-nobody-could-perform.md`. Bench `P-175`.

**The defect**: `requestEncoding()` now asks the registry, preferring gzip so the shipped
default is unchanged and declaring nothing when nothing is registered. Four of the six failures
went green by themselves.

**The remaining two** are the GUARD arms, which assert a real saving is TAKEN — impossible with
no codec. That file is now `@TestOn('vm')` for the accurate reason: every arm needs a registered
codec, and with none the guards fail while the four witnesses pass VACUOUSLY. Not because gzip
is web-only; `RpcGzipCodec` in `rpc_dart_compression` is cross-platform. The cross-platform
half of the property is **B-214**.

**A third red was hidden behind these.** `set -e` aborts at the first failing package, so the
script never reached `rpc_dart_isolate`'s two Chrome files, where the second fails to load — one
`dart test` invocation starting a second Chrome while the first shuts down. Split into two
invocations. This lead predicted exactly that ("a second red file would be invisible behind
this one") and it was right.

**Core's suite is green on node; `test:web` as a whole is not.** That Chrome red is **B-215**,
and it fails differently on every run — the same file passed alone in 6 s and later failed alone
in 95 s, with the load average climbing from 7.5 to 20.5 across the attempts. This lead's
prediction was right twice over: the second red was invisible, and it is not a small one.

## Owner decision

—
