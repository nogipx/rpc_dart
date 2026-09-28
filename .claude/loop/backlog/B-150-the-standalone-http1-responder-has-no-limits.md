---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-150 — the standalone HTTP/1.1 responder defaults to no body limit and no slow-client bound

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`RpcHttpResponderTransport()` defaults `securityPolicy` to null — any body size, no `maxActiveStreams` — and the class example uses that default; `RpcHttpServer.bodyReadTimeout` defaults to null and dart:io's idle timeout does not cover a slow body.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:60-61, 130-136, 212-217`;
`rpc_http_server.dart:95`.

## Why it matters

The documented setup is the unsafe one.

## Witness a round would build

Read; one 1 GiB upload against the documented example.

## Fix sketch

Default to `const RpcSecurityPolicy()` and a finite body timeout; opt out
explicitly.

## Owner decision

—
