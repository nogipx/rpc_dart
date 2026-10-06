---
status: closed (round 662)
release: none
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-191 — http2 responder: `_answerRejectedStream` puts a foreign error's text on the wire

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Status and message are derived by hand and `'Request rejected: $error'` sends `toString()` of whatever was thrown — bypassing the default-deny `wireStatusFor` that `_answerFramingViolation` uses for exactly this reason.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart:460-465` vs `:712`.

## Why it matters

Information disclosure on the refusal path (`protocol.dart:291-316` explains why
the gate exists).

## Witness a round would build

Force a non-Rpc error in `_handleIncomingHeaders`; read `grpc-message`.

## Fix sketch

`sendWireError` / `wireStatusFor`.

## Outcome (round 662)

REFUTED on reachability. The formatting is as read; no foreign error reaches it.
GET, an oversized value and 140 headers each answer status 3 with our own
message; a foreign `StateError` injected in place does reach the wire, so the
bench could see one. `../checked/C-65-no-foreign-error-reaches-the-http2-header-refusal.md`.

## Owner decision

—
