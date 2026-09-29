---
file: packages/core/rpc_dart/.dart_tool/probe/b116_copies_per_message.dart
round: 507
commit: cc218edc
paths: [packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/core/channel.dart]
status: valid
---

# P-145 — what does the receive-path copy cost?

## Why it exists

The lead is a copy COUNT read off the source: three or four copies per inbound
message. A count is not a cost, and a count read from source cannot say whether any
of it matters. So the bench measures time, and is built to answer the question the
count cannot: **is copying what limits this path, or is it lost under something
else?**

## The harness

Frames fed straight into `RpcFrameMultiplexedChannel` over a hand-written
`IRpcChannel`. **Deliberately not through an endpoint**: a first version echoed
through `RpcCallerEndpoint`, which puts the JSON codec in the path, and at 1 MiB the
codec dominates everything the lead is about. Measuring the layer the lead names is
the only way to attribute the time to it.

Three sizes separate per-message cost from per-byte cost — 64 B, 16 KiB, 1 MiB — and
each is run twice:

- **payload left a view**: the listener only counts. This is the receive path alone.
- **payload copied out**: the listener does `Uint8List.fromList`, which is what a
  receiver that RETAINS the message must do.

Both readings are needed and they answer different questions. A receive path that
hands out views reads as infinitely fast per byte because no byte is touched; the
second arm is the honest end-to-end figure.

## The numbers (round 507)

```
REFERENCE one 1 MiB setRange: ~37000 MiB/s

per frame                      appended      decoded in place
  64 B    view only              0.75 us         0.66 us
  64 B    copied out             0.29 us         0.27 us
  16 KiB  view only              1.72 us         0.74 us
  16 KiB  copied out             2.40 us         1.05 us
  1 MiB   view only            227.02 us         0.31 us
  1 MiB   copied out           389.76 us       191.45 us
```

The headline is the last row: **389.76 -> 191.45 us, a 2.0x end-to-end improvement
at 1 MiB** for a receiver that keeps the message. The `view only` row's 227 us is the
copy that was removed; the 0.31 us it becomes is not a throughput figure at all, it
is the absence of work.

At 64 B nothing changes, exactly as predicted from the shape: per-message cost
dominates and always did.

## Measures

Microseconds per frame, wall clock, over thousands of frames after a warm-up of 20.
The warm-up matters: JIT and the first buffer growth otherwise land inside the
measurement and make the smallest arm look slowest.

## Control

**A raw `setRange` of the same 1 MiB, so the transport figures have something to be
a fraction OF.** Without it "4302 MiB/s" is unreadable — either near the hardware
limit or two orders off it, and nothing in the transport rows says which. It reads
~37000 MiB/s, which places the old receive path at ~8x a single copy of the payload.

It is a generous reference and the record should not pretend otherwise: `src` and
`dst` stay hot in cache across 2000 reps, while the receive path allocated a fresh
buffer each time and paid for zeroing and cold pages. So the 8x is copies *plus
allocation*, not copies alone.

**The 64 B rows are the other control.** They must NOT move. If a change claimed to
remove a per-byte cost and the 64 B arm improved too, the measurement would be
picking up something other than the copy.

## What it establishes, and what it does not

Establishes: the receive-path copy is real and dominant at large sizes. Removing one
copy at 1 MiB halves the end-to-end cost for a retaining receiver and removes 227 us
of work from the path itself.

**Does NOT establish that this matters for any real transport.** 2566 MiB/s is what
the old path sustained end-to-end; a websocket or TCP link delivers one to two orders
less. The gain is real and measured, and on every transport that exists the link is
still the bottleneck. This is a cost fix, not a hang or a leak, and the record says so
rather than implying a user-visible win.

Nor does it cover the SEND path, which the lead also names (`codec -> encode ->
_encode`), or the gRPC 5-byte prefix duplicating the channel frame's length. Nothing
here was varied on that side.

The `64 B copied out` row is faster than `64 B view only` (0.29 vs 0.75) in both
tables. That is systematic rather than noise and is unexplained; it is recorded
because an unexplained systematic difference is exactly what a later round should not
have to rediscover.
