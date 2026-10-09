---
file: packages/core/rpc_dart/.dart_tool/probe/b106_minting_vs_holding.dart
round: 549
commit: 2b9ffffa
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/core/transport.dart]
status: valid
---

# P-178 — does queuing a direct object cost a pointer, or its payload?

## Why it exists

`RpcTransportMessage.bufferedBytes` returns 0 for a `directPayload`, and the code says queuing
one "costs a pointer". That is TRUE for an object the process already retains and FALSE for one
minted per message — and `P-135`, which measured the unbounded queue, drove only the minting
shape. Its 247722 messages could be read either way.

The owner's decision on B-106 waits on exactly this separation.

## The harness

400 direct objects of 1 MiB each, sent with **no consumer** — an unconsumed queue is the whole
point — and RSS read at three moments: before, after the objects exist, after they are queued.

The measure is the queue's MARGINAL retention: `afterQueue - afterBuild`. How much memory exists
because the QUEUE holds these objects, over and above what exists anyway.

- **HOLDING** — the probe keeps every object in a list of its own and then also sends it. The
  objects are not attributable to the queue.
- **MINTING** — allocated at the send site and referenced by nothing else. The queue is the only
  thing retaining them.

## The numbers (round 549)

```
  arm        RSS before   after building   after queueing   queue cost   (nominal 400 MiB)
  HOLDING       220 MiB          616 MiB          615 MiB       -1 MiB
  MINTING       217 MiB          217 MiB          530 MiB      313 MiB
```

**−1 MiB against 313 MiB.** Both claims about a direct object are true, of different shapes:
queuing one the process already holds really does cost a pointer, and queuing one nobody else
holds costs its payload.

## Measures

Resident set size, in MiB, at three points per arm. Not a rate and not a count: the question is
attribution of memory, and `P-135` already counted the messages.

## Control

**The `after building` column, and it is what caught the rig twice.**

In HOLDING it must rise by roughly the nominal payload — `220 -> 616` — because that is the arm
asserting the objects exist independently of the queue. In MINTING it must NOT move (`217 ->
217`), because nothing is built there.

**Rig error 1: the instrument was blind.** The first version allocated `Uint8List(1024*1024)`,
which is zero-filled, and a zero page need not be resident until written — building 400 MiB moved
RSS by 6 MiB and the queue cost read `1 MiB`. One byte written per 4 KiB page fixed it. Without
the `after building` column that reading would have looked like a finding.

**Rig error 2: the arms contaminated each other.** Run in one process, the second arm's baseline
was the first arm's high-water mark (`531 MiB` against `208`), so the GC was in a different state
for each and the deltas were not comparable. One arm per PROCESS, selected by argument; the two
baselines now agree to 3 MiB.

## What it establishes, and what it does not

Establishes that the two shapes differ by two orders of magnitude in what the queue retains, so
"a directPayload weighs nothing" is a statement about the SHAPE and not about the mechanism.

Does NOT establish which shape real applications use — that is a question about usage, not about
this library, and no probe here can answer it. The decision it feeds has to be taken on the risk
profile rather than on a frequency.

Does NOT measure isolate, and does not need to: `SendPort.send` deep-copies everything but
deeply-immutable values, so the pointer argument cannot apply there even in principle. Already
settled in B-106.

Does NOT read the 313 MiB as exact. The nominal payload is 400 MiB and the shortfall is GC of the
wrappers plus RSS granularity; the direction is what the arm is for.

## Reading

rpc_dart — **measures ATTRIBUTION, not a count**: how much memory exists
because the queue holds these objects, over and above what exists anyway.
`HOLDING -1 MiB` against `MINTING 313 MiB` for 400 direct objects of 1 MiB,
which settles that "a directPayload weighs nothing" is a statement about the
SHAPE rather than the mechanism. **Its `after building` control caught the rig
twice** — a zero-filled `Uint8List` is not resident until written, so 400 MiB
of allocation moved RSS by 6 and the queue cost read `1 MiB`; and both arms in
one process made the second's baseline the first's high-water mark, so the
deltas were not comparable. One arm per PROCESS, selected by argument. Cannot
answer which shape applications actually use — that is not a fact about this
library.
