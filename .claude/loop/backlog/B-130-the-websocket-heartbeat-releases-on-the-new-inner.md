---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-130 — websocket heartbeat releases its id on whatever `_inner` is current by then

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The probe creates the id on `_inner` and releases it in `finally { _inner.releaseStreamId(streamId); }`, which after a reconnect is the NEW connection — the stale-teardown hazard the class documents, harmless only because id resume keeps the ranges apart.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart:165-192`.

## Why it matters

Relies on a second mechanism to be safe; any change to id resume makes the
heartbeat release a live call's id.

## Witness a round would build

Reconnect during a probe; assert which transport receives the release.

## Fix sketch

Capture `final inner = _inner;` for the probe.

## Owner decision

—
