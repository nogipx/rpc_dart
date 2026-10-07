---
status: closed (round 709)
round: 709
commit: 5170cd3c
paths: [packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/stream_buffer_ledger.dart]
probe: .dart_tool/probe/b257_sockets.dart
reason: "measured — a sender inside its byte window still overruns the receiver's message-count cap"
---

# B-257 — small messages trip the depth cap

## Seen

`maxBufferedMessagesPerStream` (default 1024) fails a stream with
RESOURCE_EXHAUSTED once that many messages wait un-consumed. The sender is
paced by the byte window only (4 MiB), and does not know the count cap exists.
So a sender that obeys flow control still overruns the cap when its messages
are small.

Over a real websocket on localhost, default policy, a server stream of tiny
items (`.dart_tool/probe/b257_sockets.dart`):

```
ws  n=10000  fast consumer     -> ERROR after 1536 (RESOURCE_EXHAUSTED)
ws  n=3000   1 ms per item     -> ERROR after 1026
h2  same two                   -> all delivered
```

Without a socket, one chunk of up to B bytes per event-loop task
(`.dart_tool/probe/b257_chunks.dart`): 16 KiB chunks deliver 10000/10000,
64 KiB chunks fail at the cap. One chunk is parsed synchronously, so every
frame in it is admitted before the consumer runs. This is the mechanism behind
the device failures in rounds 683, 707 and 708.

## Why it matters

Any server stream of small items to a consumer slower than the producer dies
on websocket, in-memory, isolate and the wasm bridges. That is an ordinary
shape: a log tail, a list sync, a progress feed.

## Owner decision

Owner, 2026-10-07: message credit in the per-stream grant. The sender stops at
the receiver's count limit, as it already stops at the byte window.
