---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-156 — isolate: TransferableTypedData.fromList copies, contrary to the class doc

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The doc says bytes cross without a copy; `TransferableTypedData.fromList([payload])` copies once — the same as sending the Uint8List — and adds a native allocation and finaliser to every frame, most of which are tiny grants and headers.

## The shape

`packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart:43-44` vs `:95`.

## Why it matters

A net cost per small frame and a false claim.

## Witness a round would build

Frames/s for 32-byte payloads, TTD vs plain Uint8List.

## Fix sketch

Send Uint8List for small payloads (or all), fix the doc.

## Owner decision

—
