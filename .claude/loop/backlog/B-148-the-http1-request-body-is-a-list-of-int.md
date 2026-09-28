---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-148 — HTTP/1.1 caller buffers the request body in a `List<int>` and copies it again

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`bodyBuffer.addAll(data)` into a growable `List<int>` (a slot per byte), then `Uint8List.fromList` — the responder already moved to `BytesBuilder(copy: false)` and explains why.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:15, 315, 352`; compare
`rpc_http_responder_transport.dart:33-41, 333-337`.

## Why it matters

8x memory per request byte on the VM, plus a copy.

## Witness a round would build

Allocation for a 10 MiB request.

## Fix sketch

`BytesBuilder(copy: false)`.

## Owner decision

—
