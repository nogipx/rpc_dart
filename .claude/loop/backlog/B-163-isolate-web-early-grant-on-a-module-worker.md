---
status: closed (round 704)
round: 704
commit: 8253fe8a
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport_web.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-163 — isolate on web: the connection-window grant may be lost on a dart2wasm module worker

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**low-medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The transport is built, and advertises its window via `controller.sendIsolate`, before the worker has necessarily installed `onmessage`; a module worker instantiates asynchronously and drops earlier messages — the defect already fixed for the VM and wasm transports (unverified in a browser).

## The shape

`packages/transport/rpc_dart_isolate/lib/src/isolate_transport_web.dart:74-83`.

## Why it matters

Host→worker flow control silently off.

## Witness a round would build

dart2wasm worker; read `flowControlConnectionCredit` on the worker after start.

## Fix sketch

Advertise after `ready`.

## Outcome (round 704)

CONFIRMED and FIXED: on a dart2wasm module worker the worker's connection
credit read `null`, the grant lost; the host now holds its frames until the
worker reports its scope wired. `../rounds/704-the-window-grant-reaches-a-module-worker.md`.

## Owner decision

2026-10-07: take it on now.
