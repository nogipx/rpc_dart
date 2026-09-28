---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-133 — websocket `pingInterval` does nothing when the transport is constructed directly on the VM

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

On the VM `platformHonoursPingInterval` is true, so the app-level heartbeat is off, but only `connect()` puts the interval on the dart:io socket — a caller who builds the channel and passes `pingInterval:` gets no keepalive; `platformHandlesPing` is a test hook on the public API.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart:142-144`.

## Why it matters

A documented keepalive silently absent for one construction path.

## Witness a round would build

Construct directly with `pingInterval: 1s` over a half-open path; is the loss
detected?

## Fix sketch

Apply the interval to the passed socket when it is a dart:io `WebSocket`, or
reject the parameter on that path.

## Owner decision

—
