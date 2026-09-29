---
status: closed (round 534)
round: 534
commit: cbca6a2b
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
probe: P-167
reason: "CONFIRMED and FIXED as a CONTRACT gap: pause is now forwarded, but nothing in rpc_dart ever pauses a channel, so no behaviour in this library changed. The lead's real subject — what bounds a foreign peer's flood — is named in round 534's `Not fixed` and still open"
---

# B-138 — the websocket channel does not propagate pause to the socket

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_incoming` has no `onPause`/`onResume` wired to `_sub`, so a paused consumer never slows the socket; only rpc_dart's own flow control bounds a peer, which a foreign or legacy peer does not honour.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart:102, 107`.

## Why it matters

Unbounded buffering below the transport against a peer outside the protocol.

## What round 534 measured

```
  arm                          chunks pulled from source   delivered
  consumer PAUSED              5000                        0
  CONTROL not paused           5000                        5000
  GUARD paused then resumed    5000                        5000
```

Bench `../probes/P-167-does-pause-reach-the-socket.md`. After: the paused arm reads `1`.

**The witness the lead asked for would not have worked.** "RSS" is the reading P-128 established is
noise across arms here, and "a paused consumer" does not exist anywhere in rpc_dart. Reframed from
memory to DEMAND: the source is an `async*` generator counting its own yields, which suspends while
its subscription is paused, so the answer is a count. Both columns are read because the defect is
that they disagree.

## Fix

Forward pause/resume, as the sketch says — and the layer BELOW already did it: dart:io wires its own
controller's `onPause`/`onResume` to the socket subscription, so the chain was complete except for
this link.

**This closes a CONTRACT, not an observed failure.** Nothing in rpc_dart pauses a channel's
`incoming` — neither `RpcFrameMultiplexedChannel` nor `RpcChannelTransport` — so no behaviour in the
library changed. What it serves is a caller holding the channel directly and the `IRpcChannel`
promise that `incoming` is an ordinary Stream. The `cost` grading on this lead was right.

**A long pause is not free**: dart:io answers pings inside the subscription this suspends, so a
consumer that stays paused stops answering them and a peer with a keepalive calls the connection
dead. Stated in the code, not measured.

## Still open, and it is the lead's real subject

What bounds an inbound flood from a peer OUTSIDE rpc_dart's flow control. With flow control off the
bounds are `_admitToStreamBuffer` and `maxMessageLengthBytes` above the transport, and round 534
measured neither. Belongs with RPC-17's existing work and `../checked/C-29-the-real-scope-of-the-stream-limits.md`.

Also unswept: `IRpcChannel` is a documented ~50-line extension point whose own example has this same
gap, and the isolate and wasm channels were not checked (RPC-08's shape).

## Owner decision

—
