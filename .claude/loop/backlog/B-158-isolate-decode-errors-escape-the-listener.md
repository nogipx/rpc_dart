---
status: closed (round 698) — cleanup commit by owner decision
round: 698
commit: 8253fe8a
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart, packages/transport/rpc_dart_isolate/lib/src/web_bridge.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-158 — isolate (VM and web): a malformed frame throws inside the port listener

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**low**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`message.data as RpcMetadata` and `_materializeBytes` (VM `:164, 585-596`), `raw['methodPath'] as String?`, `decodeMetadata`, `materializeBytes` (web `:98, 268, 309`) run in the data callback; a throw is an uncaught zone error — fatal on a worker (`errorsAreFatal`), and on web a worker `error` event that closes the connection.

## The shape

`packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart:164, 585-596`; `web_bridge.dart:98, 268, 309`.

## Why it matters

Only a malformed peer reaches it; the damage is the whole isolate instead of one
stream.

## Witness a round would build

Post a malformed message to the worker port.

## Fix sketch

Catch and fail the stream.

## Outcome (cleanup, after round 698)

Both handlers (VM and web) now dispatch inside a try and put a decode failure
on the incoming stream as an error, where the transport fails the connection,
instead of throwing into the zone. `fromMap` reads a non-string `methodPath`
as absent instead of throwing. Not witnessed: every sender of these frames is
this library's own code, so no malformed frame was produced.

## Owner decision

2026-10-07: hygiene leads are **done as cleanup commits, without rounds**.
