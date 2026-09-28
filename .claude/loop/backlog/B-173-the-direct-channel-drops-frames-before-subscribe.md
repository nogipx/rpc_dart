---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-173 — RpcDirectMultiplexedChannel is a sync broadcast that starts pumping in its constructor

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_incomingCtl` is `StreamController.broadcast(sync: true)` fed from the constructor; frames arriving before the transport subscribes are dropped — including the connection-window grant; `memoryPair` is safe only because both transports are built in one expression, the public `pair()` with an await in between is not.

## The shape

`packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart:16-28`.

## Why it matters

The defect fixed in isolate and wasm, still present in the public in-memory
channel.

## Witness a round would build

`pair()`, build the client transport, `await Future.delayed(0)`, build the server
transport; read the client's `flowControlConnectionCredit`.

## Fix sketch

Use `BufferedBroadcastController` like `RpcFrameMultiplexedChannel`.

## Owner decision

—
