---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/hpack_expansion.dart
round: 237 — the validating round
commit: cb4312fe
paths: [packages/transport/rpc_dart_http2/lib/**]
status: valid
---

# P-16 — what does a header block cost once it is decoded?

Builds a real HPACK block by hand — prime the dynamic table with one ~4000-byte
entry, then N one-byte indexed references to it — decodes it with
`package:http2`'s own `HPackDecoder`, and then runs rpc_dart's
`http2HeadersToRpcMetadata` over the result. Sizes are chosen to sit just under
the 64 KiB header-block guard, so every arm is a request the guard ADMITS. Run
it with `melos exec --scope=rpc_dart_http2 -- fvm dart run
.dart_tool/probe/hpack_expansion.dart`.

## Measures

Three numbers per arm, all on the library's side. **Decoded header count**;
**distinct objects** among them (`identityHashCode`, which is what tells a
shared reference from a copy); and **RSS around each stage separately**, so the
decoder's cost and the conversion's cost are attributed to the right one.

## Control

The two stages ARE each other's control — same input, same block, one
measurement each:

```
  refs    wire KiB   headers   logical MiB   RSS +MiB   distinct
  1000           5      1001           3.8          0          1
 10000          14     10001          38.2          1          1
 60000          63     60001         229.3          7          1     <- decode

 rpc_dart's conversion of those same headers
 10000          14                                  31
 60000          63                                 258              <- convert
```

`distinct: 1` is the load-bearing number: package:http2 hands back thousands of
pointers to ONE entry, so the classic HPACK bomb costs it almost nothing, and
the 229.3 MiB "logical" column is what an implementation that copied would pay.
rpc_dart then paid it — 258 MiB — because `String.fromCharCodes` per header is a
copy. After the fix both conversion arms read `RSS +0, REFUSED`.

**A counter-hypothesis was tested, not assumed.** The first reading of the
decoder said "unbounded List<Header>, therefore a bomb"; the identity column is
what refuted that and moved the finding one layer up.

Lens: `../lenses/RPC-18-dependency-buffers-below-your-limits.md`.
