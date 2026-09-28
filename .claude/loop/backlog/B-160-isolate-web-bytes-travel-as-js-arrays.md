---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_isolate/lib/src/web_bridge.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-160 — isolate on web: payload bytes cross as arrays of boxed numbers

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`serializeBytes` is `data.toList(growable: false)`; isolate_manager `.jsify()`s it to a JS Array, structured clone copies it element by element, `dartify` yields a list of numbers, and `materializeBytes` maps and copies it back — about four boxed O(n) passes where one memcpy (or an ArrayBuffer transfer via isolate_manager's `transferables:`) would do.

## The shape

`packages/transport/rpc_dart_isolate/lib/src/web_bridge.dart:300-316`.

## Why it matters

Web worker throughput dominated by per-byte work.

## Witness a round would build

MB/s for 1 MiB payloads host→worker on Chrome.

## Fix sketch

Send the Uint8List (structured clone keeps typed arrays) or transfer its buffer.

## Owner decision

—
