---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-155 — isolate: three ReceivePorts stay open when Isolate.spawn throws

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`initPort`, `errorPort` and `exitPort` are opened before `await Isolate.spawn(...)` with no try; an unsendable `customParams` value makes spawn throw and the open ports keep the process alive.

## The shape

`packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart:312-328`; `teardownStartup` exists only after.

## Why it matters

A CLI or test process that fails to spawn never exits.

## Witness a round would build

`spawn(customParams: {'x': ReceivePort()})` in a script; does it exit?

## Fix sketch

try/catch closing the three ports.

## Owner decision

—
