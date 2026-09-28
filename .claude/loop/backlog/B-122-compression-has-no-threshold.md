---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/core/compression.dart, packages/core/rpc_dart/lib/src/core/compression_gzip_io.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
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

## Owner decision

—
