---
status: closed (round 513)
round: 513
commit: 3be26273
paths: [packages/core/rpc_dart/lib/src/core/compression.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/core/compression_gzip_io.dart]
probe: P-151
reason: "the growth half is CONFIRMED and fixed — 42 -> 62 bytes at 32 B, crossover between 192 and 256 — by comparing sizes rather than the threshold the sketch asks for. The zero-copy half is REFUTED: memoryPair answers identity. CPU, the fromList copies, and the unclosed zlib sink are untouched"
---

# B-122 — compression applies to every message of any size, and crosses isolate boundaries

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`compressionEnabled` gzips every request regardless of size, a responder gzips every response whenever the client advertised gzip; on a zero-copy transport in codec mode the caller never sets `grpc-accept-encoding: identity`, so the base `identity,gzip` makes the server gzip across an isolate boundary; `rpcGzipCompress`/`Decompress` add a `Uint8List.fromList` copy.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart:150-166` (both branches gated on
`!transport.supportsZeroCopy`); `compression.dart:182-190`
(`selectResponseEncoding`); `compression_gzip_io.dart`. When the size limit throws inside the chunked
gzip decoder, `sink.close()` is never reached and the native zlib filter waits for
the finaliser.

## Why it matters

Tiny messages grow and cost CPU; in-process calls pay for compression that buys
nothing.

## Witness a round would build

Bytes on the wire and CPU for 32-byte unary messages with compression on; the
isolate codec-mode case: is the response compressed?

## Fix sketch

A size threshold; set `identity` whenever the transport is in-process.

## Outcome (round 513) — one claim confirmed, one refuted

**Growth CONFIRMED.** Incompressible payload, request frame bytes:

```
          before            after
  32 B    42 -> 62          42 -> 42
 192 B   202 -> 206        202 -> 202
 256 B   267 -> 253        267 -> 253    <- crossover, unchanged
4096 B  4107 -> 3138      4107 -> 3138
```

gzip's fixed overhead is about twenty bytes; the crossover sits between 192 B (+4)
and 256 B (−14).

**Zero-copy REFUTED.** On `memoryPair`, both sides reporting `supportsZeroCopy:
true`, the response comes back `grpc-encoding: NONE (identity)`. The responder does
not gzip across the in-process boundary. Both header branches in `caller_pipeline`
ARE gated on `!supportsZeroCopy` as the lead says — something else declines to
compress, and what that is was not established.

**Fixed by comparing, not by the sketch's threshold**, and the control row is the
argument: a 32-byte REPEATED payload still compresses 42 → 33, which any threshold
above 32 would discard. Comparing also needs no number that is right for one kind of
traffic and wrong for another. `RpcGrpcCompression.compressIfSmaller` returns the
bytes and the per-message flag; three sites call it. It is safe because the frame's
compression flag is per MESSAGE, so `grpc-encoding: gzip` with an individual message
sent plain is ordinary gRPC and the existing decoder already handles it.

**A probe-design note worth keeping**: the first version used `'a' * n` while testing
whether compression makes messages BIGGER — the case least likely to grow. It
reported a saving at 32 B and would have refuted a true claim.

## Split out to B-206 (cost) and B-207 (the zlib sink) — not measured

**CPU, which is half of "grow and cost CPU".** The growth is fixed; comparing pays
slightly MORE CPU, since compression still runs on payloads that end up sent plain.
Nothing measured it, so this is unknown rather than dismissed — and a size threshold
is the right tool for that half, sitting in front of the comparison rather than
instead of it.

**`rpcGzipCompress`/`Decompress` still add a `Uint8List.fromList` copy.**

**The unclosed zlib sink.** When the size limit throws inside the chunked gzip
decoder, `sink.close()` is never reached and the native filter waits for the
finaliser. That is a resource question rather than a cost one and deserves its own
round.

## Owner decision

—
