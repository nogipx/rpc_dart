---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-142 — HTTP/1.1 responder routes by the full request path

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`methodPath = request.requestedUri.path`; mounted under `/rpc/` (the doc says it can be mounted anywhere) the path is `/rpc/Svc/M` — refused as invalid or unimplemented.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:249`.

## Why it matters

The documented composition does not work.

## Witness a round would build

shelf_router mount at `/rpc/`; one unary call.

## Fix sketch

`'/${request.url.path}'`.

## Owner decision

—
