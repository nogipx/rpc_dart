---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-192 — http2 server: onConnectionClosed fires twice; a socket read in the accept path can kill the isolate

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The preface timeout calls `_releaseEndpoint` then `socket.destroy()`, and `socket.done` calls `_releaseEndpoint` again — no idempotency guard; `'${socket.remoteAddress}:${socket.remotePort}'` runs outside the try in the accept callback, and the class's own comment says `remotePort` throws OS Error 22 once the peer is gone; `stop()` closes endpoints serially (N x up to 2 s); `start()` is not re-entrant; `createWithContracts` drops ping and preface options; the "nothing has subscribed yet" comment at `:570-572` is probably false.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart:165-200, 324-349, 362-401, 457-463, 474-475, 535-554, 566-612`.

## Why it matters

Double callbacks to user code; a peer that connects and resets immediately can
end the server process.

## Witness a round would build

Preface timeout 100 ms, connect and send nothing; count `onConnectionClosed`.
Connect-and-RST loop against the accept path.

## Fix sketch

Guard `_releaseEndpoint`; move the address read inside the try; `Future.wait` on
stop.

## Owner decision

—
