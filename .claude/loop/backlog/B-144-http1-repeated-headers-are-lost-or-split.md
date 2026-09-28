---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-144 — HTTP/1.1: repeated headers are last-wins on requests and every response header is split on commas

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`request.headers[name] = value` keeps the last duplicate; the response side splits EVERY header on `,` — `date` becomes two entries and a foreign `grpc-message` containing a comma (legal per spec) is cut; the responder never splits shelf's comma-joined repeats.

## The shape

Caller `packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:344-350, 436-467`; responder
`rpc_http_responder_transport.dart:267-270`.

## Why it matters

Metadata differs from what was sent, in both directions.

## Witness a round would build

Send two values of one custom key; read them server-side. Server sends
`grpc-message: a, b` via a raw handler.

## Fix sketch

Join on send; split only custom keys, never `grpc-message` or standard headers.

## Owner decision

—
