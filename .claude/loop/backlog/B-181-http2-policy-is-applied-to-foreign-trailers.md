---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-181 — http2 caller: our header policy is enforced on the peer's trailers and destroys the real status

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`http2HeadersToRpcMetadata(..., policy: _policy)` and `_policy.validateMetadata` run on trailers too; a foreign server's `grpc-status-details-bin` over 8 KiB, raw UTF-8 in `grpc-message`, or more than 128 headers throws — the consumer gets INVALID_ARGUMENT then a synthesised UNAVAILABLE instead of the real status, and each counts toward the 256 violations that close the connection.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:1243-1249, 1308-1312`.

## Why it matters

Interop with grpc-go/grpc-java servers that attach rich error details.

## Witness a round would build

grpc-go server returning a status with 10 KiB of details.

## Fix sketch

Always extract `grpc-status`/`grpc-message` first; apply limits as caps, not
refusals, on trailers.

## Owner decision

—
