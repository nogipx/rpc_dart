---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-178 — http2 caller: `_discardConnection` says runZonedGuarded, does try/catch

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The doc says it runs inside `runZonedGuarded` rather than behind a `catchError`; the body is `try { connection.terminate(); } catch`, and the Future `terminate()` returns is neither awaited nor handled — an async error from it reaches the root zone.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:1691-1702`. Related: B-35 (closed by the
owner) on `finish()`; this is a different call site.

## Why it matters

A potential process kill on reconnect; a comment that describes code that is not
there.

## Witness a round would build

Reconnect while the old connection's socket errors.

## Fix sketch

Attach `.catchError` (or actually zone-guard it) and fix the comment.

## Owner decision

—
