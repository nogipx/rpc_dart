---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-140 — HTTP/1.1: an abandoned call keeps its request and body read running

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`releaseStreamId` only removes map entries; `_httpClient.send` and `_readBounded` continue to the end; `AbortableRequest` (package:http 1.6) is unused; the `maxActiveStreams` slot is already free, so the ceiling stops bounding real sockets.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:274-278, 354`.

## Why it matters

Cancelled and timed-out calls keep sockets and bandwidth until the server stops.

## Witness a round would build

Cancel 20 slow-streaming calls; count open sockets at the server.

## Fix sketch

Build `AbortableRequest` with an abort trigger completed from `releaseStreamId`
(this also gives the transport a real `IRpcStreamReset`).

## Owner decision

—
