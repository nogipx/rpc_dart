---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-141 — HTTP/1.1 responder: the body-read timeout does not stop the read, and `_reject`'s drain always fails

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`readBody().timeout()` abandons the future while `await for (request.read())` keeps running; `_reject` then calls `request.read()` a second time, shelf throws StateError, and `catch (_)` swallows it — the 408/413/400 drain never runs, nor does the one in `close()`.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:156-172, 363-370, 410-418, 573`.

## Why it matters

The defect `_reject`'s own doc describes, present; C-31 measured that the read
stops accepting after the 408 — the reader itself is still running.

## Witness a round would build

Slow-body client past `bodyReadTimeout`; is the original read subscription still
active? Does `_reject`'s drain throw?

## Fix sketch

Read through a subscription that the timeout cancels; drain from that
subscription instead of calling `read()` again.

## Owner decision

—
