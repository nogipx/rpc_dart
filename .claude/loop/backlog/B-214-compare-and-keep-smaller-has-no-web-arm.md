---
status: open
round: 543
commit: b566bcb8
paths: [packages/core/rpc_dart/test/core/compression_never_makes_a_message_bigger_test.dart, packages/core/rpc_dart_compression/test/rpc_dart_compression_test.dart]
probe: none
reason: "round 543 made the round-513 file VM-only for a correct reason, which leaves the property it asserts unmeasured against the only gzip codec that exists on the web"
---

# B-214 — compare-and-keep-smaller has no web arm

Split out of round 543, which closed B-211.

Round 513 established that compression must not be applied unconditionally, because gzip's
fixed overhead makes small incompressible payloads larger on the wire. Round 543 marked that
file `@TestOn('vm')`, because every arm needs a registered codec and core registers none on
dart2js — with none, the two GUARDs fail and the four witnesses pass VACUOUSLY (`on == off`).

So the property is now asserted on the VM's built-in `dart:io` gzip and nowhere else.

## Why that is a gap rather than a non-question

`RpcGzipCodec` in `rpc_dart_compression` **is** cross-platform: it is backed by
`package:archive`, its own doc describes the web inflate path in detail, and
`melos run test:web` already runs that package's suite on node.

Two codecs, two implementations, and the property is about a RATIO — whether the compressed
form is smaller than the input at 32, 64, 128 and 192 bytes. Nothing says `package:archive`'s
gzip has the same fixed overhead as `dart:io`'s, and `compressIfSmaller` keeps whichever is
smaller per message, so a different overhead changes which arm flips. That is exactly the kind
of number that does not travel between implementations.

## Where it belongs

`rpc_dart_compression`, not core. The codec lives there, the package's suite already runs on
both targets, and core cannot depend on it — the dependency runs the other way, so a core test
that registered `RpcGzipCodec` would be a dev cycle.

## Witness a round would build

The round-513 table, re-measured with `RpcGzipCodec` registered, on the VM and on node:
request DATA frame size with compression off against on, at 32/64/128/192 incompressible bytes,
plus the two guards (a large incompressible payload and a small compressible one must both
still shrink).

The interesting outcome is a DISAGREEMENT between the two codecs at some size. If they agree,
the lead closes having established that the threshold-free rule holds for both.

## Owner decision

—
