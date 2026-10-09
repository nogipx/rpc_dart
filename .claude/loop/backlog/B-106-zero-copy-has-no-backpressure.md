---
status: closed (round 550)
release: breaking
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

## The measurement (round 549) — both claims are true, of different shapes

`../rounds/549-a-pointer-or-a-payload.md`. Bench `P-178`.

```
  arm        RSS before   after building   after queueing   queue cost   (nominal 400 MiB)
  HOLDING       220 MiB          616 MiB          615 MiB       -1 MiB
  MINTING       217 MiB          217 MiB          530 MiB      313 MiB
```

**−1 MiB against 313 MiB.** Queuing a direct object the process already holds really does cost a
pointer, exactly as the code claims. Queuing one nobody else holds costs its whole payload, and
the queue is then the only thing retaining it. The claim was never wrong — it was a statement
about the SHAPE, and nothing said so.

The `after building` column is the control and it caught the rig twice: a zero-filled `Uint8List`
is not resident until written (400 MiB of allocation moved RSS by 6), and running both arms in
one process made the second arm's baseline the first arm's high-water mark. One arm per PROCESS
now, baselines agreeing to 3 MiB.

## What is still the owner's, and it is narrower now

The decision's fork — *is holding the rare shape or the common one* — **cannot be resolved by
measurement here**: which shape an application uses is a fact about applications, and no probe in
this repository reaches it.

**But the fork may not need resolving.** A per-stream EVENT ceiling, the queue depth this lead
already named as the only bound an operator can set meaningfully, is correct for BOTH arms:

- on MINTING it is the only thing bounding memory at all, and 313 MiB from 400 messages is what
  is at stake;
- on HOLDING it costs nothing real — the objects exist either way, so refusing the 1001st is
  honest backpressure about the QUEUE, whose own cost measures `-1 MiB`.

So the question put back is not "which shape is common" but: **add a per-stream queue-depth
ceiling for direct objects, given it is safe under both shapes?** It is a new public policy
field, and pinning what it counts is the B-209 / B-128 trap from a third side — which is why it
is asked rather than taken.

## Outcome (round 550) — the ceiling is in, and it found a second queue

`../rounds/550-a-queue-depth-for-an-object.md`. **Owner's answer: add it.**

```
  arm                                      queue cost   (nominal 400 MiB)
  HOLDING, paused per-stream consumer         -33 MiB
  MINTING, paused per-stream consumer         270 MiB
  MINTING, paused, depth 64                    71 MiB   <- 64 messages x 1 MiB
```

`RpcStreamBufferLedger` gained an EVENT dimension beside its byte one; both are charged on every
message and whichever is reached first binds. `maxBufferedMessagesPerStream`, default 1024, and
its doc states what it counts and why nothing else — the lesson B-209 and B-128 both paid for,
applied before the field shipped.

**Three places needed the count and not just the bytes**, each a defect on its own: `release`
returns the event charge even for a zero-byte message (or a zero-copy stream is admitted
`limitEvents` times and refused for ever, the inversion round 536 recorded), `forget`/`clear`
drop the count, and `trackedStreams` counts either dimension.

**The probe had to be moved, and that is the sharpest part.** There are TWO queues on the receive
path: `incomingMessages`, the connection-wide broadcast, is also sized by `bufferedBytes` and
therefore also unbounded for direct objects. Measuring through it read `355 MiB` with a depth of
64 configured — a ceiling that appeared not to work, because the per-stream ledger was never
charged at all. Filed as **B-217**; that bound is per-CONNECTION and a different field.

**`P-135` cannot see this fix.** It counts what the producer generated and this bounds residency
at the receiver — the paused zero-copy arm still reads 314569 produced, because nothing paces the
producer.
