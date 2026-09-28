---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/core/channel_frame.dart, packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-115 — a metadata frame over `maxMetadataBytes` is buffered in full before it is refused

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_decodeAt` returns null for an incomplete payload BEFORE it checks `maxMetadataLen`, so a server (`closeOnOversizedFrame: true`, where `_refusedFrameHeader` is off) buffers up to the DATA ceiling (16 MiB) of a frame whose header already says it is a 64 KiB-limited metadata frame.

## The shape

`packages/core/rpc_dart/lib/src/core/channel_frame.dart:107-134`: the `maxPayloadLen` check, then
`if (data.length < payloadStart + payloadLen) return null;`, and only then the
metadata-size check. `decodeAll`'s doc promises rejection "from the header alone".

## Why it matters

256x more memory per hostile frame than the metadata limit implies, on transports
that deliver bytes incrementally (not dart:io websocket, which delivers whole
messages).

## Witness a round would build

Feed a frame header declaring a 10 MiB metadata payload, then the payload in
64 KiB chunks; observe when the refusal fires and the buffer size at that point.

## Fix sketch

Move the metadata-size check above the completeness check.

## Owner decision

—
