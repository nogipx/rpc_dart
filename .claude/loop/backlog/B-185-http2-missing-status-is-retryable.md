---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-185 — http2 caller: a clean end without grpc-status becomes retryable UNAVAILABLE

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

A peer that ends the stream cleanly with no trailers (a server bug; the request may have run) is reported UNAVAILABLE, which `RpcRetryInterceptor` retries; grpc-go reports INTERNAL for that and keeps UNAVAILABLE for a lost connection.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:1170-1193`. B-86 closed the end-flag half
of this; the status choice was not in it.

## Why it matters

Non-idempotent work retried after it ran.

## Witness a round would build

Raw h2 server: headers + data + END_STREAM, no trailers; status and retry count.

## Fix sketch

INTERNAL for a clean end without status; UNAVAILABLE only for connection loss.

## Owner decision

—
