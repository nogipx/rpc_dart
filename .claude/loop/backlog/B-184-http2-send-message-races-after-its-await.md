---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-184 — http2 caller: sendMessage and finishSending race a disposed or parked pump

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

If release/reset/reconnect disposes the pump while `add` is parked on the window, `add` returns silently and the send reads as success; the id is then re-added to `_halfClosedLocal` after cleanup (one leaked entry per stream); `finishSending` while a `sendMessage` is parked puts END_STREAM first, and the parked message is dropped — the request is truncated with no error.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:996-1000, 1034-1038`; `rpc_http2_common.dart:158-167`
(waiters can also be overtaken by a new `add`).

## Why it matters

Silent request truncation — the class of defect B-74 fixed in core.

## Witness a round would build

Client-stream with a closed peer window: `send(x)` parked, `finishSending()`;
server's received count.

## Fix sketch

Make disposal fail parked adds; order END_STREAM behind parked data.

## Owner decision

—
