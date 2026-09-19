---
file: packages/core/rpc_dart/.dart_tool/probe/unary_broadcast_fanout.dart
round: 393
commit: 74e5e117
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-82 — what N live unary handlers cost every other frame

## Why it exists

`UnaryResponder` listens to the whole connection broadcast and filters inside an
`async` callback, so every inbound frame allocates a Future per live handler,
whatever stream it belongs to. The owner reported it as a profile item at
hundreds of concurrent calls; this puts a number on it.

## Measures

Wall clock for a FIXED load — 3000 frames pumped upstream — while N unary calls
are parked in their handlers, each leaving one live broadcast listener.

Median of five runs per point, not a mean within one (measurement.md item 9).

## Control

**N = 1.** The fan-out cannot exist with a single handler, so that column is the
machine's own noise. A reading where it moves with the others is measuring the
machine; across this session it sat between 36 and 61 ms while the N=200 column
moved 333 -> 94.

## The direction mistake, and the instrument that caught it

The first version pumped with a **server-stream** and read a flat
36 / 22 / 31 ms. That is the answer a bench gives when there is no defect AND
when it cannot reach one, and only an instrument separates them.

Two counters planted in `UnaryResponder` — live subscriptions and listener
entries — read **3 entries for a 3000-frame pump**. The parked responders live
on the SERVER, whose broadcast carries inbound frames only; a server-stream
pumps the other way and never touches them.

Pumped upstream through a client-stream, the same counter reads **600 400
entries at 200 parked handlers**: exactly N per frame. The counters were removed
once they had done their job; what they established is recorded here instead.

## The numbers (round 393)

```
parked unary handlers      1        50       200
before                    48 ms   126 ms   333 ms
after                     38 ms    42 ms    94 ms
```

## What it establishes, and what it does not

Establishes: the per-frame cost of a live unary handler, and that making the
listener synchronous removes most of it — 3.5x at 200 handlers with the control
unmoved.

Does NOT establish anything about the fan-out COUNT, which is unchanged: 200
handlers still mean 200 listener invocations per frame. Nor about a real
transport, since this runs on an in-process pair — the cost measured is CPU per
frame, which a socket adds to rather than replaces.
