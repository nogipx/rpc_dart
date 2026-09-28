---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-146 — HTTP/1.1 responder emits two content-type values

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-low**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The header map starts with `application/grpc+proto` and the pipeline's initial metadata adds `application/grpc`, merged into a list; dart:io keeps the last, other adapters may emit two lines; the `+proto` ignores what was requested.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:502, 511-521`.

## Why it matters

Ambiguous responses through non-dart:io shelf adapters and proxies.

## Witness a round would build

Serve through `shelf`'s test handler; inspect `Content-Type` values.

## Fix sketch

One content-type, echoing the request's subtype.

## Owner decision

—
