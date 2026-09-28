---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-149 — HTTP/1.1 caller sets `te: trailers`, which nothing uses and browsers refuse

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The status travels in ordinary response headers on this wire format; `te` is a forbidden header name in browsers (XHR logs "Refused to set unsafe header" on every call).

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:341-342`, doc `:88-91`.

## Why it matters

Console noise per call on web; a misleading comment.

## Witness a round would build

Browser test: console warnings per call.

## Fix sketch

Remove it.

## Owner decision

—
