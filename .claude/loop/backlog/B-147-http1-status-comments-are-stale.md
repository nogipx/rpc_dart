---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-147 — HTTP/1.1 comments describe a status table core no longer has

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`:404-409` cites `_httpStatusToGrpcCode` and 400 → INVALID_ARGUMENT; core's `grpcStatusFromHttpStatus` maps 400 → INTERNAL and 405/408/415 → UNKNOWN, so a metadata violation reaches the caller as INTERNAL and a body timeout as UNKNOWN (not retryable).

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:404-409`, `packages/core/rpc_dart/lib/src/core/protocol.dart:211-220`.

## Why it matters

The comment argues a retry semantics the code no longer has; 408 → UNKNOWN is a
real behaviour question: whether a body timeout should stay UNKNOWN is a decision for the shared table.

## Witness a round would build

Read.

## Fix sketch

Fix the comment; decide whether 408 should be UNAVAILABLE/DEADLINE_EXCEEDED in
the shared table.

## Owner decision

—
