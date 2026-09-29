---
status: decided by owner (round 540)
round: 497
commit: 60e4d3f8
paths: [packages/core/rpc_dart/lib/src/core/transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart, packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
probe: P-135
reason: "owner decision — CONFIRMED by round 497; both halves of the fix sketch are decisions rather than repairs (new public policy, or reversing rounds 208 and 214)"
---

# B-106 — zero-copy (in-memory, isolate) calls have no backpressure at all

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`bufferedBytes` is 0 for a `directPayload`, `sendDirectObject` is never metered by flow control, and the direct channel's `send` is an immediate `add`; a fast server-stream handler against a slow consumer fills the client's per-stream controller without limit, and the ledger never trips on zero bytes.

## The shape

`packages/core/rpc_dart/lib/src/core/transport.dart:71-79` ("A `directPayload` weighs nothing ... queuing it
costs a pointer"). `channel_transport.dart:535-560`: `sendDirectObject` claims the
ending but never calls `_fc.tryConsume`. `direct_multiplexed_channel.dart`
`send` → `_output.add(message)`. The producer side awaits
`processor.send` → `_sendSequence` → `sendDirectObject` → resolves at once.
The isolate transport declares `supportsZeroCopy => true` (`isolate_transport.dart:78`)
and deep-copies every object through `SendPort`.

## Why it matters

"A pointer" holds only for an object the process already retains; a handler that
creates a new object per message makes the queue as large as everything it
produced. Pausing the consumer pauses the metered view but the controller keeps
buffering. On isolate the "zero-copy" branch is additionally a deep copy per
message, which can cost more than the codec path it replaces.

## Witness a round would build

`RpcInMemoryTransport.pair()`, zero-copy server stream producing 1 KiB objects in
a tight loop; consumer pauses after the first message. RSS after 2 s. Control:
the same with codecs (flow control applies).

## Fix sketch

Count direct objects against a per-stream event ceiling (or a nominal weight per
object) and let `sendDirectObject` park on credit like `sendMessage`. Reconsider
whether isolate should claim `supportsZeroCopy`.

## Round 497 — CONFIRMED, and the confirming arm is not the obvious one

```
mode      consumer   window       produced   received
zeroCopy  PAUSED     4096 KiB      247722          1
zeroCopy  draining   4096 KiB      211212     211212
codec     PAUSED     4096 KiB      189274          1
codec     draining   4096 KiB      152568     152568

the window made tiny, paused consumer
zeroCopy  PAUSED       64 KiB      274289          1
codec     PAUSED       64 KiB        5960          1
```

**Only the last two rows confirm this lead.** The first four say both paths run
away equally, which is the opposite conclusion — and it is what the round would
have reported had it stopped there, because `checked/C-19` records that the
library does not throttle producers at all by decision. "The producer got ahead"
is therefore expected on every path and carries no information.

Shrinking the window 64-fold moves the codec path 32x and zero-copy not at all.
That is what separates *unmetered* from *metered with a generous bound*.

The lead's "it is only a pointer" caveat is the right one: the bench mints a fresh
1 KiB object per message, so nothing else in the process retains it.

## Why the fix is an owner decision, not a repair

Both halves of the sketch are choices:

1. **A nominal weight per object is new public policy.** There is no honest byte
   count for an arbitrary Dart object, so the knob is a fiction the operator has
   to size — and `RpcSecurityPolicy` carries an explicit warning against adding a
   field nothing enforces, which is the same trap from the other end.
2. **Parking on credit reverses a decision taken twice.** Round 208 chose to
   refuse a stalled call rather than pause the producer; round 214 withdrew B-15
   when it would have restored throttling. `checked/C-19` records both.

The options, with the measurement already done: a nominal per-object weight; a
per-stream EVENT ceiling for direct objects (no fictional byte count needed); or
accept it and document that zero-copy means no backpressure.

**Not measured**: the isolate half. `supportsZeroCopy => true` while every object
is deep-copied through `SendPort`, so the "zero-copy" branch there may cost more
than the codec path it replaces. Untouched by this round.

**Split out**: the codec path's window is itself an order of magnitude looser than
its number (185 MiB retained at a 4 MiB window). That was this round's control
rather than its subject and is now **B-195**.

## Owner decision

**MEASURE FIRST, then decide** — taken in the round-540 review.

The owner's question was the right one and it is not answered by this record: **why does
backpressure mean anything on a path that exchanges objects rather than byte frames?** The
honest parts of the answer are that `bufferedBytes` is 0 for a `directPayload` and the code
says queuing one "costs a pointer" — true for an object the process ALREADY retains — and
that round 497's own arm mints a fresh 1 KiB per message precisely so nothing else holds it.

So the decision waits on one measurement, and the fix options are ranked differently by its
outcome:

**Separate a MINTING producer from a HOLDING one.** Same rig as P-135, two arms:

1. the handler creates a new object per message (what 497 drove) — the queue is as large as
   everything produced;
2. the handler sends an object the process already retains and keeps retaining — the queue
   really is a list of pointers, and the memory is not attributable to it.

If (2) is the rare shape, in-memory's severity rises and a count-based ceiling is obviously
right. If (2) is the common shape, the bound belongs only where the object is COPIED, which
is isolate.

**What is already established and must not be re-derived.** `SendPort.send` deep-copies
everything but deeply-immutable values, and the isolate transport's own doc says
`supportsZeroCopy` there means "sendDirectObject works", not "the peer sees the same
instance". So on isolate the pointer argument does not apply even in principle — that half
needs no further measurement, only a decision.

**And the nominal per-object weight is off the table.** It is a fiction an operator cannot
set meaningfully; if a bound is wanted, it is a per-stream EVENT ceiling — a queue depth,
which is what every other queue here is bounded by and needs nothing invented. That still
creates a public field whose meaning has to be pinned exactly, which is the B-209 / B-128
trap seen from a third side.
