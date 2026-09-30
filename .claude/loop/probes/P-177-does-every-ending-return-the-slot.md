---
file: packages/core/rpc_dart/.dart_tool/probe/b128_every_ending_returns_the_slot.dart
round: 546
commit: bd8ed066
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-177 — does every way a call can end return its slot?

## Why it exists

`P-157` asks whether the client ceiling BINDS. This asks the opposite question, which is the
one the fix for it can get wrong: holding a slot until completion turns "admits too much" into
"refuses everything for the life of the connection" if any ending forgets to give the slot back.

The two are different instruments. P-157 fills the ceiling and looks for a refusal; this one
looks for a refusal that must NOT be there.

## The harness

Per arm, `ceiling + 2` calls through ONE ending shape, run one after another against a ceiling
of 2, over a byte pipe where each side carries its own policy — a shared policy would make a
server's refusal indistinguishable from the client's.

The endings: completion, an error status, a cancel, a deadline, and a peer that stops answering
(the channel simply drops everything). Each is a different path to "this call is over", and only
two of them involve a terminal frame.

**Sequential, with a pause between calls**, so a slot released one turn late still counts as
released. The question is whether it comes back at all, not how promptly.

## The numbers (round 546)

```
  ending                   admitted  REFUSED  other   (of 4, ceiling 2)
  completion                     4        0      0
  error status                   4        0      0
  cancel                         4        0      0
  deadline                       4        0      0
  peer stops answering           4        0      0
  CONTROL overlapping            0        2      2   <- refuses, so the instrument works
```

## Measures

Refusals with `RESOURCE_EXHAUSTED`, counted per arm. An answered call is an answered call
whatever its status — NOT_FOUND, CANCELLED and DEADLINE_EXCEEDED all mean the slot's owner
finished with it.

## Control

**The last row, and the probe is worthless without it.** Five rows of zero refusals are equally
consistent with "no slot leaks" and with "the ceiling does nothing at all". The control runs
calls that never end inside the arm, so the ceiling MUST refuse — and it does, 2 of 4.

The first version of this probe had no such row and would have read identically against a
ceiling that had been deleted. Its own label said `<- A SLOT LEAKED` on the control, which is
the correct outcome there; the label now distinguishes the two.

## What it establishes, and what it does not

Establishes that all five endings return the slot, with an instrument shown able to report a
refusal.

Does NOT identify WHICH mechanism returns it — for that see round 546's canaries, which found
two independent ones covering different endings. This probe reads the outcome only, and would
stay green with either one removed.

Does NOT cover the streaming shapes. A client-stream call holds its request stream open, so it
may be counted for its whole life either way, and nothing here varies that.
