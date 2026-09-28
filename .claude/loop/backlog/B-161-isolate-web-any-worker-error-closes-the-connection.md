---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport_web.dart, packages/transport/rpc_dart_isolate/lib/src/web_bridge.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-161 — isolate on web: any `messageerror` or worker `error` event closes the transport

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The death listener closes on both events; `messageerror` is one undeserialisable message — `WebMultiplexedChannel.send` itself calls that "ONE message's problem, not the connection's" — and a worker `error` is any uncaught exception in a still-running worker; `WebMultiplexedChannel` also closes on any stream error.

## The shape

`packages/transport/rpc_dart_isolate/lib/src/isolate_transport_web.dart:207-211`; `web_bridge.dart:131-133, 181-187`.

## Why it matters

One bad message or one stray async error ends every call on the worker.

## Witness a round would build

Worker handler with an unawaited throwing future; is the connection closed?

## Fix sketch

Fail only on worker termination; treat `messageerror` per message.

## Owner decision

—
