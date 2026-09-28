---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/core/parser.dart, packages/core/rpc_dart/lib/src/core/channel_frame.dart, packages/core/rpc_dart/lib/src/core/protocol.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-116 — channel transports copy each inbound message three or four times, and frame it twice

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Receive: every chunk is appended into `_buf` even when the buffer is empty and the chunk holds whole frames, then `parser.addBytes` copies it (`Uint8List.fromList`), then `sublist` copies the body; send: codec → `RpcMessageFrame.encode` (copy) → `RpcChannelFrame._encode` (copy); the 5-byte gRPC prefix duplicates the channel frame's own length on a message-aligned channel.

## The shape

`packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart:392` `_appendToBuffer(data)`
unconditionally; payloads are views into `_buf`, which doubles its capacity, so a
retained message pins up to 2x its buffer. `parser.dart:39` and `:227`.
`channel_frame.dart:237-245` and `protocol.dart:88-108` on send.
`_encodeMetadataPayload` adds `Uint8List.fromList(utf8.encode(...))` (`:258`).

## Why it matters

Bandwidth-bound copying on websocket, isolate and the frame pair for every
message; http2 additionally re-frames (`emitFramed`) and the processor de-frames
again.

## Witness a round would build

Throughput and allocation per message for 64 B, 16 KiB and 1 MiB unary echo over
the frame pair, before and after.

## Fix sketch

Decode directly from the chunk when `_bufLen == 0`; hand the parser views instead
of copies; consider dropping the gRPC prefix on message-aligned channels (a wire
change — owner decision).

## Owner decision

—
