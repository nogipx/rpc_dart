---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-182 — http2 caller: no timeout on connect, TLS handshake or connect-to-proxy

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`SecureSocket.connect`, `Socket.connect`, the proxy `Socket.connect` and `SecureSocket.secure` have no timeout; `proxyHandshakeTimeout` covers only the CONNECT response, and the comment at `:470-474` names this exact risk; single-flight reconnect makes every caller join a hung attempt.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:320-324, 440, 470-474, 556, 675`.

## Why it matters

An application that hangs at startup against a black-holed host.

## Witness a round would build

Connect to a black-holed address.

## Fix sketch

One connect timeout covering socket, TLS and proxy phases.

## Owner decision

—
