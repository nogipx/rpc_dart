---
status: closed (round 703)
round: 703
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/http2_header_block_guard.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-193 — http2 common: headers validated twice, rebuilt per call, walked two or three times

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_headerValue` re-implements `isValidHeaderValue` after `validateMetadata` already ran; response and trailers-only builders are near-copies and only the latter guarantees content-type; the request path can emit `te` twice and does not filter connection-specific headers; constant headers are re-encoded per call; `extractRequestMethod`/`extractMethodPath`/`extractHttpStatus`/`http2HeadersToRpcMetadata` each `String.fromCharCodes` every header; `filterStreamEvents` is test-only while its doc calls it live; `kGrpcUserAgent = 'rpc-dart/1.0.0'`; keepalive pings a busy connection; the guard and proxy forwarder pass no pause/resume to the socket.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart:13, 60-78, 244-304, 356-411, 438-556, 590-608`;
`http2_header_block_guard.dart:59-94`; caller `:579` (`forwardCtrl`).

## Why it matters

Per-call cost and a protocol risk (connection-specific headers are malformed in
HTTP/2).

## Witness a round would build

Requests/s with a profiler on header conversion.

## Fix sketch

One conversion pass, cached constant headers, one builder, forward pause/resume.

## Progress (round 697)

The protocol item is done: a connection-specific header in user metadata
reached the handler over http2 (`connection -> v` and four more); it is now
refused before it is sent, INVALID_ARGUMENT, on every transport. `te` twice is
not reachable from user metadata (`te` is reserved). The cost items remain.
`../rounds/697-connection-headers-are-refused-on-send.md`.

## Outcome (round 703)

The cost items measured: header build 0.72 us and parse 0.25 us per request
against a 475 us unary call over h2, about 0.2%. Not worth a change.
`../rounds/703-header-conversion-is-a-fifth-of-a-percent.md`.

## Owner decision

2026-10-07: connection-specific headers **refused on send** with
INVALID_ARGUMENT, as edge whitespace in round 679.
