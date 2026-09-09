---
refines: —
paths: [packages/transport/rpc_dart_isolate/lib/**, packages/core/rpc_dart/lib/src/core/buffered_broadcast.dart, packages/transport/*/lib/**]
applies: a producer starts before the consumer subscribes, and the carrier in between drops rather than buffers
breaks: broken delivery.
applied: []
status: confirmed (round 168, off-journal)
---

# RPC-20 — The window before the first listener

## Shape

Setup awaits a readiness signal and only then subscribes — but the peer has been
producing since before that signal, and a plain `StreamController.broadcast()`
**discards** anything added while nobody is listening. Everything sent in that
window is silently gone.

It fails OPEN, which is why it survives: what is lost is usually a handshake or
an advertisement, and its absence reads as "the peer does not support this
feature" — the deliberate degradation path for an old peer. Nothing errors.

## Detector

Every `spawn`, `connect` and `attach` where a readiness `Completer` is awaited:
does the subscription go on BEFORE or AFTER that await? Then every
`StreamController.broadcast()` on an inbound path — each is a place where
pre-listener data dies. Compare against
`BufferedBroadcastController`, which retains and flushes on first listen.

Second clause, and it is a separate bug that hides behind the first: a
transport that reserves a stream id for its own handshake must not filter that
id WHOLESALE. Check what else legitimately travels there — in rpc_dart, stream 0
carries core's `x-rpc-conn-window-update`, and neither of core's own channels
filters it.

## Ask

Does anything the peer sends between its construction and this side's first
`listen()` reach a consumer? Count it — do not reason about the ordering.

## Evidence

**`rpc_dart_isolate`, two independent holes fixed together in 38a5a17f**, because
either alone left connection-level flow control off:

1. **The pre-ready window.** `spawn()` attached the host's channel only after
   `await ready.future`. The worker builds its `RpcChannelTransport` — whose
   constructor advertises the connection window — and runs the user entrypoint
   BEFORE acking readiness, so that whole advertisement went on the floor.
2. **Stream 0 was filtered.** `_IsolateMultiplexedChannel._handleMessage`
   returned early for every frame with `streamId == 0`. Those handshake messages
   are a distinct enum type, so a `metadata` frame there is never a handshake —
   it is the connection window update.

Measured with an 8 KiB connection window, per-stream window off, an inert worker:

    before   200/200 chunks got out    <- unbounded, the window never arrived
    after      8/200

Today the fix is visible at `isolate_transport.dart:552-561` (channel and
transport constructed) against `:571` (`await ready.future`), and at `:156`,
where stream 0 is documented as reserved and its metadata frames are delivered
rather than dropped.

> **`BufferedBroadcastController` does NOT fix half (1), and that is the trap.**
> Its flush runs synchronously from inside `listen()` — i.e. from the channel's
> own constructor — into an `_incomingCtl` that `RpcChannelTransport` has not
> subscribed to yet, so the frames are dropped one hop later instead. Subscribing
> EARLY closes the window at both hops; the channel and transport constructions
> are synchronous and back to back, so no port message can land between them.
> A buffering carrier only helps at the hop it is on.

Imported from private memory in the curate pass after round 234.
