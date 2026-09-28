---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/core/transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart, packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-106 — zero-copy (in-memory, isolate) calls have no backpressure at all

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`bufferedBytes` is 0 for a `directPayload`, `sendDirectObject` is never metered by flow control, and the direct channel's `send` is an immediate `add`; a fast server-stream handler against a slow consumer fills the client's per-stream controller without limit, and the ledger never trips on zero bytes.

## The shape

`packages/core/rpc_dart/lib/src/core/transport.dart:71-79` ("A `directPayload` weighs nothing ... queuing it
costs a pointer"). `channel_transport.dart:535-560`: `sendDirectObject` claims the
ending but never calls `_fc.tryConsume`. `direct_multiplexed_channel.dart`
`send` → `_output.add(message)`. The producer side awaits
`processor.send` → `_sendSequence` → `sendDirectObject` → resolves at once.
The isolate transport declares `supportsZeroCopy => true` (`isolate_transport.dart:78`)
and deep-copies every object through `SendPort`.

## Why it matters

"A pointer" holds only for an object the process already retains; a handler that
creates a new object per message makes the queue as large as everything it
produced. Pausing the consumer pauses the metered view but the controller keeps
buffering. On isolate the "zero-copy" branch is additionally a deep copy per
message, which can cost more than the codec path it replaces.

## Witness a round would build

`RpcInMemoryTransport.pair()`, zero-copy server stream producing 1 KiB objects in
a tight loop; consumer pauses after the first message. RSS after 2 s. Control:
the same with codecs (flow control applies).

## Fix sketch

Count direct objects against a per-stream event ceiling (or a nominal weight per
object) and let `sendDirectObject` park on credit like `sendMessage`. Reconsider
whether isolate should claim `supportsZeroCopy`.

## Owner decision

—
