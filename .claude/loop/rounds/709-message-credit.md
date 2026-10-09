---
round: 709
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-17
bench: none — `.dart_tool/probe/b257_sockets.dart` (websocket and http2 on localhost) and `.dart_tool/probe/b257_chunks.dart` (a channel delivering one chunk of up to B bytes per task, optional latency)
commit: yes
release: changelog
severity: S2
---

# Round 709 — message credit

## Target

B-257: a sender inside its byte window still overruns the receiver's
message-count cap. The mechanism behind the device failures of rounds 683,
707 and 708, which were found on a bridge but are not specific to one.

## Hypothesis

`maxBufferedMessagesPerStream` bounds un-consumed messages, and the sender
knows only the byte window (4 MiB). One inbound chunk is parsed synchronously,
so every frame in it is admitted before the consumer runs. A chunk carrying
more than the depth of one stream's frames fails it.

## Before

Chunk rig, 10000 tiny items, fast consumer:

```
chunk 4 KiB    10000/10000
chunk 16 KiB   10000/10000
chunk 64 KiB   RESOURCE_EXHAUSTED after 1536
```

Websocket on localhost, default policy:

```
ws  10000 items, fast consumer      ERROR after 1536
ws  3000 items, 1 ms per item       ERROR after 1026
h2  both                            all delivered
```

## Mechanism

As hypothesised. A slow consumer trips it at any chunk size: the byte window
lets the sender put hundreds of thousands of small messages in flight, and the
depth fires at 1024.

## Fix

Owner's choice among three (message credit, count only zero-copy, pause reads):
message credit in the per-stream grant.

- Every per-stream grant frame carries `x-rpc-window-update-messages` beside
  `x-rpc-window-update`; the receiver returns one message per consumed payload
  or direct object, granted at half the depth.
- The sender seeds message credit at its own depth and parks at zero.
- The peer's first grant REPLACES the seed, less what was sent under it. The
  first version added it, and the websocket probe still failed at 2560 and
  1027: the advertisement is the whole window, not an increment.
- A byte grant without the header marks the peer as pacing bytes only; the
  seed is dropped and parked senders woken.
- `sendDirectObject` takes message credit, no bytes.
- The ledger and the responder's request budget count payloads and direct
  objects only, as the sender does; a bare metadata frame is bounded by bytes.
- `IRpcFlowControlled.returnFlowCredit` is called once per message, 0 bytes
  allowed.

Depth default 1024 -> 8192, owner's choice after the cost below.

## After

```
chunk 64 KiB, 10000 items           10000/10000
ws  10000 and 100000, fast          all delivered
ws  3000, 1 ms per item             3000/3000
```

The cost: the depth is now an in-flight window. 20000 tiny items, fast
consumer, chunk rig with one-way latency:

```
                 10 ms     50 ms
HEAD              136       316   ms   (but fails a slow consumer)
depth 1024        696      2374
depth 4096        246       772
depth 8192        193       542
depth 16384       173       431
```

## Canary

`_messageWindow` forced to null: both core witnesses and all three websocket
tests fail at the depth.

## The verdict questions

1. Yes: Before on the same tree, probes kept.
2. Yes: websocket, the transport the user named first, and the core layer
   every channel transport shares.
3. Yes: items delivered, and time for the cost.
4. Not zero-valued.
5. Quoted.
6. One cause; the first fix attempt exposed a second rule (seed replacement),
   tested on its own.
7. A trade, asked: the owner chose depth 8192 knowing the latency table.
8. One test premise changed: `a_direct_object_queue_has_a_depth_test` now
   expects a metered sender to park at the depth and a sender without flow
   control to be refused.

## Gate

`analyze`, `format:check`, `check:skills`, `test:unit`, `test:web`,
`test:wasm`. The full `test` fails only in the minio/postgres/redis packages.

## Not fixed

- A sender with flow control off, or one predating this, still trips the depth
  on a burst; that is what the depth is for.
- A peer with the per-stream window off and the connection window on never
  grants per stream, so a sender parks at its seeded 8192 messages until the
  5 s grace, as it already did at the 64 KiB byte seed.
- `maxMessagesPerChunk` (1024 per inbound chunk, in the parser) is unmeasured
  against http1 response bodies, where one read may carry more small messages.

## Links

Lead `../backlog/B-257-small-messages-trip-the-depth-cap.md` closed.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` -- `applied: [..., 709]`.
