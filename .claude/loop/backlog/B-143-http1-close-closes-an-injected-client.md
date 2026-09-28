---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-143 — HTTP/1.1 caller closes an `http.Client` it did not create

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`close()` calls `_httpClient.close()` even when the client was passed in; ownership is not documented; in-flight calls each log an error during an orderly close.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:154, 498, 602`.

## Why it matters

A shared client breaks for every other user.

## Witness a round would build

Inject a client, close the transport, use the client.

## Fix sketch

Close only a client the transport created.

## Owner decision

—
