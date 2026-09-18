---
status: open
round: 392
commit: a82bcf4c
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: none yet — the code facts are confirmed by reading; what needs measuring is the COST of the obvious fix
reason: bench — the fix removes an error path a previous round added deliberately, and whether that loses anything depends on a transport state nobody has produced yet
---

# B-57 — every unary handler subscribes to the whole connection

Reported by the owner (U1). Every code fact below is confirmed by reading.

`UnaryResponder._setupRequestHandler` does
`_transport.incomingMessages.listen(...)` — the **whole connection's** broadcast
— and `_onIncomingMessage` then discards what is not its own:

```dart
if (id != 0 && streamId != id) return;
```

Meanwhile `responder_pipeline.dart:1257` builds it with `id: streamId` and feeds
the request itself, four lines later:

```dart
final responder = UnaryResponder<IRpcSerializable, IRpcSerializable>(
  id: streamId, ...);
state.responder = responder;
...
await responder.handleMessage(savedMessage);
```

So for a pipeline responder the subscription delivers **nothing**. What it costs
is one `async` listen callback per inbound frame per live unary handler — a
Future allocation and a microtask each — which is O(N) per frame in the number
of concurrent unary calls. Invisible at ten, a profile item at hundreds.

Its `onError` is not nothing, though, and that is the catch.

## Why it was not fixed in round 392

Dropping the subscription for `id != 0` also drops its `onError`, which answers
every unhandled stream with a trailer. The comment there says why it was added:
*"Logging alone leaves the caller waiting for a response that will never come."*

The owner's note says the pipeline covers it through `_abortActiveStreams`. It
covers PART of it:

- `responder_pipeline.dart:410` `onDone` -> `_abortActiveStreams` — cancels
  tokens and cleans up. Transport dead, nothing to answer over. Covered.
- `responder_pipeline.dart:403` `onError` — **logs only**.

So for a transport error that does NOT close the incoming stream, removing the
subscription leaves the caller waiting where today it gets a trailer. Whether
that state is reachable is the measurement this lead is waiting on:
`channel_transport.dart:168` pushes a non-advisory error to every per-stream
controller AND to `_incoming`, and an advisory one only to `_incoming` — so the
question is whether a non-advisory error ever arrives without the channel then
closing.

## A better fix than the one proposed

Subscribe to **`getMessagesForStream(id)`** rather than to the broadcast, when
`id != 0`. It fixes both halves of U1 at once and loses nothing:

- per-stream, so the O(N) fan-out is gone;
- `channel_transport.dart:182` withholds `IRpcAdvisoryChannelError` from
  per-stream controllers while still delivering real failures — which is exactly
  the second half of the owner's report, the advisory error that wrongly fails a
  unary call in the window between the constructor and `handleMessage`.

Check first that every transport's `getMessagesForStream` has the same
semantics; http2's is the one to read.

## Owner decision

None needed. This is a bench problem: the fix direction is clear and the missing
piece is a measurement of what the current `onError` actually saves.
