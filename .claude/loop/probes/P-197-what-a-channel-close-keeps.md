---
file: packages/core/rpc_dart/.dart_tool/probe/b174_close_asymmetry.dart
round: 576
commit: b9a491c4
paths: [packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/core/multiplexed_channel.dart]
status: valid
---

# P-197 — what does a channel close keep, and what does a send on a closed one do?

## Why it exists

B-174's claims 2 and 3. Both are about a moment rather than a quantity, so the rig has to create the
moment: **both ends queue a frame in the same event-loop turn and then one closes**, with nothing
awaited between the three calls. Awaiting any of them lets the queue drain and the question disappears.

## The harness

`RpcDirectMultiplexedChannel.pair()` with a listener on each end recording an `x-tag` header, so which
side received which frame is readable rather than inferred from a count.

Three arms: the client closing, the server closing (the same question mirrored, which is how "the
closing side loses" is told apart from "the client loses"), and a send issued after the peer has closed
— reading what the send did, what the peer got, and this side's own `isClosed`.

## The numbers (round 576)

```
CLAIM 3  the CLIENT closes
    the client received  []
    the server received  [from-client]
CLAIM 3  the SERVER closes
    the client received  [from-server]
    the server received  []
CLAIM 2  send after the peer has closed
    the send           returned normally
    the peer received  []
    our isClosed       true
```

Unchanged by the round. Claim 3's asymmetry is kept deliberately and claim 2 is pinned; what the round
added is both rules on the interface plus their witnesses.

## Measures

Which tagged frames each side received, and for claim 2 three facts at once: the send's outcome, the
peer's inbound list, and the sender's own `isClosed`. The third is what turned claim 2 from "the peer is
gone" into "this side knows it is closed and still reports success".

## Control

**The mirrored arm is the control for claim 3**: swapping which side closes swaps which side loses, so
the rule is about closing and not about the client role.

**For claim 2, `our isClosed` is the control on the premise** — without it a silent send could be a
channel that had not noticed the peer yet, which is a different defect.

## What it establishes, and what it does not

Establishes both claims, and that claim 3 is symmetric.

**Establishes what the obvious fix costs**, which is the round's real finding: a one-turn yield before
the cancel delivers the peer's frame, and the turn lands inside the close cascade either side of
`_output.close()`, so `in_memory_transport_test`'s named requirement — "a send with nowhere to go is
refused, not reported sent" — fails. Both orderings were tried.

Does NOT cover `RpcFrameMultiplexedChannel`, whose `send` has the same `if (_closed) return` by reading
but whose close ordering was not driven.

Does NOT measure how often the race matters in practice — whether a real peer typically has a frame
queued at the moment the other side closes.
