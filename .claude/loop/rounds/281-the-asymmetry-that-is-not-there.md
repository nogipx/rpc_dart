---
round: 281
verdict: INCONCLUSIVE
packages: [rpc_dart]
lens: RPC-01
bench: none
commit: yes
---

# Round 281 — the asymmetry that is not there

## Target

The half round 280 named with line numbers: `_fcOweConnection`, `_fcDischarge`
and `_fcOnDelivered` charge `payload?.length ?? 0` at six sites. Rounds 279 and
280 had just found the same expression wrong in two memory budgets, so the
question was whether flow control is the third.

RPC-01 — credit is not returned for a frame nobody consumes, per level and per
layer.

## Hypothesis

An ASYMMETRY: the sender spends window on a frame that the receiver credits back
at zero. That is the under-crediting family of rounds 206 and 266, and its
consequence is not a memory bound but a permanent wedge — the peer's window
drains to nothing and never refills.

## Before

No bench. The hypothesis is refuted by reading both ends, which is cheaper than
measuring and is what rule one asks for first:

```
ChannelTransport.sendMetadata      line 518   no _fcTryConsume, no _fcAwaitCredit
ChannelTransport._fcOnConsumed     line 1012  if (bytes == 0) return;
```

Nothing is charged for a metadata frame and nothing is credited back. The two
ends agree, so no credit can leak, and the six sites are consistent with each
other. **There is no third instance of the round 279/280 defect here.**

## Mechanism

n/a — the hypothesis does not hold.

## After

n/a.

## Canary

n/a.

## Gate

n/a — no code changed. `loop.py lint` green.

## Not fixed

The question the reading leaves is real and this round could not answer it, so
the verdict is INCONCLUSIVE rather than CLEAN: **metadata is exempt from flow
control entirely**, at both ends, so a peer's metadata is never paced. After
rounds 279 and 280 something does stop a flood — the queue's byte bound, now
that it weighs metadata — but that is a HARD bound: the connection is failed
where a payload flood would merely have been throttled. Fine for a hostile peer,
wrong for a legitimate client that simply outruns a slow consumer.

Filed as **B-28** with a two-arm probe design (payload versus metadata against a
real transport with a consumer that does not read, measuring whether the sender
ever parks and which mechanism finally stops it). It needs the transport rather
than P-29's controller fill, because the question is about the SEND path — which
is why this round's budget could not be stretched to cover it honestly.

What was tried, per the INCONCLUSIVE rule: only the reading. No bench was built,
because the reading disposed of the hypothesis the round set out with and the
remaining question needs a different observable.

## Links

RPC-01 (`applied:` gains 281). Lead B-28, new. Round 280 is what named the
sites; its "Not fixed" section is now answered in its first half and deferred in
its second.
