---
status: closed (round 676)
release: changelog
round: 676
commit: 81530a7b
paths: [packages/core/rpc_dart/lib/src/core/parser.dart, packages/core/rpc_dart/lib/src/core/compression.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
probe: .dart_tool/probe/parity_matrix.dart (5.stream-item-over-limit), .dart_tool/probe/codec_mode_response.dart
reason: owner decision — the owner asked for the finding to be recorded, not fixed
---

# B-249 — an oversized message on memory and isolate reads as INTERNAL

Measured outside a round, by the transport parity matrix (`probe:` above), at the `commit:` sha.

Policy `maxMessageLengthBytes: 65536` on both sides. One message of 66560 bytes:

```
                          memory/isolate                     websocket / http1 / http2
server-stream item        13 "Compressed gRPC payload could   8 (each with its own text)
                          not be decompressed: it is
                          malformed, or it expands beyond
                          the configured limit"
unary response, codec     13, same text                       8
unary request, codec      8 "Too much buffered before the     8
                          responder took it (max: 1024
                          messages, 65541 bytes per stream...)"
```

The user did not ask for compression. On a transport without zero-copy the
caller declares `grpc-encoding` and `grpc-accept-encoding` itself
(`caller_pipeline.dart:168`), and `compressIfSmaller` gzips any message that
shrinks. So the oversized message arrives compressed. The limit then fires
inside the decompressor, where `parser.dart:310` cannot tell a bomb from corrupt
input and answers INTERNAL on purpose. The websocket and HTTP transports reach
the size check before decompression and answer RESOURCE_EXHAUSTED. Why only the
in-process transports end up compressed is not measured.

The request side gets the right code but names the wrong limit: the per-stream
buffer budget fires before the message limit does.

## Why it matters

The same contract behaves differently depending on the transport. Code that
catches RESOURCE_EXHAUSTED for "message too big" gets INTERNAL on memory and
isolate. The text then sends the reader looking for a malformed payload.

## Outcome (round 676)

FIXED as decided: every gzip limit overrun is RESOURCE_EXHAUSTED, malformed
input stays INTERNAL. The oversized stream item now reads 8 on all five
transports. The request-side text naming the buffer budget is unchanged (status
already 8). `../rounds/676-a-size-the-decompressor-called-malformed.md`.

## Owner decision

2026-10-07, round 676's batch: **fix** -- the decompressor reports an expansion
past the limit as RESOURCE_EXHAUSTED, malformed input stays INTERNAL.
