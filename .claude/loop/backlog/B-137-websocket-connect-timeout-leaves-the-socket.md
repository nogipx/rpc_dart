---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-137 — websocket connect timeout abandons the wait, not the TCP attempt

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`Future.timeout` stops waiting while the TCP connect continues until the OS gives up, holding a descriptor for minutes against a black-holed address.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart:78-96`.

## Why it matters

Descriptor build-up under a reconnect loop against an unreachable host.

## Witness a round would build

Connect to a black-holed address 100 times with a 100 ms timeout; count open fds.

## Fix sketch

Pass `customClient: HttpClient()..connectionTimeout = connectTimeout`.

## Owner decision

—
