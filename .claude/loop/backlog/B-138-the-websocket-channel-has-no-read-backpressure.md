---
status: open
round: 534
commit: cbca6a2b
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: P-167, P-210, P-211, P-212
reason: "bench — round 594 bounded every per-stream request buffer (client-stream sink and unary pre-bind were unbounded against a peer ignoring grants, both fixed). What is left is the CONNECTION total: 4096 streams × 16 MiB per stream, arithmetic and not measured, plus the unswept IRpcChannel example and the isolate and wasm channels"
continuation: yes
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

### Round 593 narrowed it and did not settle it (INCONCLUSIVE)

```
                                      PULLED   delivered   errors   resident
CONTROL  flow control ON, 64 KiB      20001        0          0      +34 MiB
WITNESS  flow control OFF             20001        0          0      +40 MiB
```

320 MiB offered as 20000 frames of 16 KiB on one peer-minted stream, consumer paused. `P-210`.

**Established: the transport reads every frame and flow control does not change that.** Not a defect
by itself, and it corrects this lead's own framing — rpc_dart's flow control is a SEND-side credit
protocol. It bounds what this side sends and asks the peer to stop by withholding grants, so against
a peer that ignores grants it does nothing, and it never throttles READING.

**Not established: whether `_admitToStreamBuffer` is reached at all.** `+34 MiB` against 320 MiB
offered with nothing refused means the frames are DISCARDED, and the likeliest cause is the rig — a
peer-minted stream with no `RpcResponderEndpoint` attached has nowhere to be dispatched.

**Three rig failures, recorded so the next round does not repeat them:**

1. A `StreamController` source measures the BENCH: `+316 MiB` with flow control ON, `+300` with it
   OFF, which is the controller queueing 320 MiB with no peer waiting for credit.
2. A data frame for a stream nothing opened is silently dropped, so an arm feeding only data frames
   reads `delivered 0, errors 0` everywhere and looks like a bound.
3. `health().details` carries no buffer depth — `activeStreams` counts streams THIS side opened,
   `streamControllers` counts `getMessagesForStream` calls.

**What the next round needs, precisely:** attach an `RpcResponderEndpoint` with a handler that never
returns, so a peer-minted stream is dispatched and buffered where `_admitToStreamBuffer` can refuse
it. Then read `PULLED`, the first error and residency across flow control off,
`maxBufferedMessagesPerStream` default and lifted, and N streams against `maxActiveStreams` — the
per-stream bound TIMES the stream ceiling is the total a peer can command, and that product is the
number this lead is asking for.

Also unswept: `IRpcChannel` is a documented ~50-line extension point whose own example has this same
gap, and the isolate and wasm channels were not checked (RPC-08's shape).

### Round 594 — the per-stream half, FIXED

With a responder attached (`P-211`), the per-stream bound turned out to apply to
bidi and server-stream only. A parked client-stream handler held `19999` of 20000
messages (~312 MiB; honest peer `257`, bidi `1023`), and frames sent on a unary
stream while its handler ran grew RSS 1:1 (`P-212`). Both now apply
`effectiveMaxBufferedBytes` and `maxBufferedMessagesPerStream` and answer
RESOURCE_EXHAUSTED. `../rounds/594-the-two-buffers-the-stream-bound-never-saw.md`.

**What remains is the product.** Every per-stream bound multiplies by
`maxActiveStreams`: 4096 × 16 MiB on one connection from a peer ignoring grants.
Nothing bounds the connection's total of un-consumed request bytes except the
connection window, which such a peer ignores. Unmeasured — the next round's
witness is N parked streams against P-211's rig.

## Owner decision

—
