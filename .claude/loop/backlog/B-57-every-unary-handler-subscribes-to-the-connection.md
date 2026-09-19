---
status: open — the COST half fixed in round 393, the fan-out COUNT remains
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

## A better fix than the one proposed — WRONG, struck out in round 393

> The idea was: subscribe to `getMessagesForStream(id)` rather than to the
> broadcast. **Reading the transport before building on it refutes that.**
> `getMessagesForStream` CREATES a per-stream controller
> (`channel_transport.dart:316-328`), and routing then takes a different branch:
> `_admitToStreamBuffer` can refuse a frame and `return` at line 885 — *before*
> the unconditional `_incoming.add(message)` at line 913. So a unary request
> over the per-stream byte bound would be dropped from the PIPELINE too, by a
> bound that does not apply to unary today. It also moves unary streams from
> credit-on-arrival (`_fc.onConsumed`, the `else` branch at 904) to
> owed-until-consumed. Not a free swap, and it would have shipped a silent
> request-drop.
>
> Kept rather than deleted: a refuted direction is worth as much as a confirmed
> one to whoever reads this next.

## What round 393 did instead

Made the listener SYNCHRONOUS with the id filter first, so a foreign frame costs
a comparison rather than a Future. **48 / 126 / 333 ms -> 38 / 42 / 94** for
3000 frames at 1 / 50 / 200 parked handlers (P-82). And added the
`IRpcAdvisoryChannelError` check in `onError`, which is the second half.

## What is still open

**The fan-out COUNT.** 200 handlers still mean 200 listener invocations per
frame; only the allocation behind each is gone. Removing the count needs the
subscription itself to go, and the only per-stream route is the refuted one
above. Options left:

- have the PIPELINE deregister the responder's listener once it has fed the
  request, since it owns both ends;
- or give `UnaryResponder` a mode where the pipeline promises to feed it and no
  subscription is made at all — which is what the owner originally proposed, and
  which needs the `onError` answer path replaced rather than dropped, because
  the pipeline's own `onError` logs only.

## Owner decision

None needed. This is a bench problem: the fix direction is clear and the missing
piece is a measurement of what the current `onError` actually saves.
