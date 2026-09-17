---
status: open
round: 368
commit: e897128e
paths: [packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart]
probe: —
reason: bench — the sibling's own number was taken on a different API and does not transfer; this needs a stalled-handler run against requestSink itself
---

# B-49 — `BidirectionalStreamCaller.requestSink` has no back-pressure

The same sibling pair round 368 found its crash in, one axis over.

`ClientStreamCaller.call(Stream)` pauses its request subscription for the
duration of each send, and its own comment says why, with the number:

> Measured with a handler that consumed one message and stalled, against a 1 MB
> window, the caller pulled all 2000 messages (32.8 MB) from its request stream.

`BidirectionalStreamCaller.requestSink`'s listener does neither — no
`pause()`, no `resume()`. The controller is therefore never paused, so an
application feeding the sink (directly or through `addStream`, which honours a
pause it never receives) runs ahead of the transport without bound. Ordering is
not at risk: `CallProcessor.send` queues onto `_sendSequence` synchronously
before its first await. Memory is.

## Why it is not fixed in round 368

That round's subject was the crash, and its fix is one try/catch per callback.
Adding pause/resume changes when the application's producer runs, which is a
behaviour change with its own witness and its own canary, and the 32.8 MB figure
above belongs to the OTHER API — quoting it for this one would be passing a
neighbouring measurement off as this one's.

## What would close it

A handler that consumes one message and stalls, a small window, and a count of
how many messages `requestSink` pulls before the first send completes — the
shape `ClientStreamCaller` was measured with, pointed at `requestSink`. Then the
same pause/resume the sibling already has.

Note the endpoint's own bidi bridge (`_buildBidirectionalStream`) does NOT use
`requestSink`; it drives its own subscription. So the exposure is an application
holding `BidirectionalStreamCaller` directly, which is public API.

## Owner decision

—
