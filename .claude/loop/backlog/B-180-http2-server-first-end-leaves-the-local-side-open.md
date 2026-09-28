---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-180 — http2 caller: when the server ends first, the request side is never ended or reset

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`onDone` removes `_activeStreams`/`_halfClosedLocal` but not `_outgoingPumps`; `releaseStreamId`'s RST branch needs the stream in `_activeStreams`, `finishSending` returns early — the local half stays open unless the server RSTs; later sends fail with "Send metadata first".

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:765-777, 975-979, 1015, 1196-1202`.

## Why it matters

Stream and pump leak against servers that do not RST (non-rpc_dart servers).

## Witness a round would build

grpc-go server answering a client-stream before the client half-closes; inspect
stream state.

## Fix sketch

End or reset the local side in `onDone` when it is still open.

## Owner decision

—
