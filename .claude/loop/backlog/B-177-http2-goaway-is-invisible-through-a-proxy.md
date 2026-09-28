---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-177 — http2 caller: GOAWAY is never detected on the proxy path

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Both `_guardedConnection(...)` calls in `_connectH2ViaProxy` omit `drainSignal:`, so `goawayReceived` stays false — a draining connection is reported as MAX_CONCURRENT_STREAMS (RESOURCE_EXHAUSTED, "retry when one completes") and `health()` says healthy.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:680-698, 861-869, 1666-1673`.

## Why it matters

The misclassification the drain signal was built to prevent, on every proxied
deployment.

## Witness a round would build

Proxy + server `drain()`; next call's status and health.

## Fix sketch

Pass the drain signal on both proxy branches.

## Owner decision

—
