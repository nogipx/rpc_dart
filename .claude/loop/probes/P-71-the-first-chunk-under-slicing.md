---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/first_chunk_fields_under_slicing.dart
round: 383
commit: 6a3cb2c1
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/**]
status: valid
---

# P-71 — the first chunk under slicing

## Why it exists

B-44's ranked list of unmeasured suspects put the NETWORK PATH second:
production is `wss://` through an ingress and every bench so far has been a bare
local socket. toxiproxy's `slicer` is that difference in its sharpest form for a
framed protocol — it cuts writes at boundaries the sender never chose.

## Measures

The consumer's exact shape: 17 chunks, the first carrying `blobId` / `vaultId` /
`total` and the rest payload only. **Every field is a function of the index**,
which is what B-44 asks for — it makes a lost, reordered, duplicated and
mis-decoded message four distinguishable outcomes rather than one, a distinction
the consumer's own logs cannot make.

Reported per arm: whether the handler's FIRST message had its ids, and how many
messages it got in total.

Rig: real websocket server, client through toxiproxy with a `slicer` on the
upstream (`average_size: 128`, `size_variation: 64`, `delay: 1000`), against the
same server direct.

## Control

An ablation in `_handleDataMessage` dropping a client-stream's request frames:
every arm went `handler got 17` -> `handler got 0`.

**Its weakness is recorded because it decides the verdict.** It was meant to drop
only the FIRST frame and produce the consumer's symptom exactly; it removed the
responder's dispatch too. So what is demonstrated is that the probe separates
*delivered* from *not delivered* — not that it would recognise the specific
shape of B-44. Round 383 is INCONCLUSIVE on that basis rather than CLEAN.

A sharper control is the obvious first improvement: drop frame index 0 only,
after the responder exists, and confirm the probe prints
`FIRST CHUNK HAS NULL IDS`.

## The numbers (round 383)

```
arm                        result
direct, small              first ok (index=0) | handler got 17
direct, 256 KiB chunks     first ok (index=0) | handler got 17
SLICED, small              first ok (index=0) | handler got 17
SLICED, 256 KiB chunks     first ok (index=0) | handler got 17
```

## What it establishes, and what it does not

Establishes: splitting writes at arbitrary offsets does not reproduce B-44.
WebSocket framing reassembles above TCP, so the parser never sees the split.

Does not cover COALESCING (the inverse toxic), the consumer's pinned `55159adf`,
or Electron's renderer. It also runs on the VM, while B-44 is reported on
dart2js — so it tests the wire, not the runtime.
