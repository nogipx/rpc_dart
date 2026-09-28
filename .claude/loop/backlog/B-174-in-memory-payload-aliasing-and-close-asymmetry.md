---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/rpc/transports/in_memory_transport.dart, packages/core/rpc_dart/lib/src/core/transport.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-174 — in-memory: payloads are aliased and delivered later; close drops frames asymmetrically; two names for one factory

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_output.add(message)` passes the Uint8List by reference and delivers it a microtask later, so a sender reusing its buffer after `await sendMessage` corrupts what the receiver reads (only `directPayload` carries a warning); `send` after the peer cancelled reports success; `close()` delivers our queued frames and drops the peer's; `RpcInMemoryTransport.pair` is `RpcChannelTransport.memoryPair`.

## The shape

`packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart:45-54`;
`in_memory_transport.dart:22-26`; `core/transport.dart:29-32`.

## Why it matters

Silent data corruption for buffer-reusing senders; confusing API.

## Witness a round would build

Send, mutate the buffer, read on the receiver.

## Fix sketch

Document (or copy) payload ownership; pick one public name.

## Owner decision

—
