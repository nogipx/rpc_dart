---
round: 497
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-01
bench: P-135 — new
commit: yes
severity: S1
---

# Round 497 — vary the limit to see whether it is the limit

## Target

The audit's thirteenth lead, on zero-copy backpressure — `open` when this round
took it, and `awaiting owner` because of what the round found. The lead is named
in `## Not fixed`, where the question now sits.

Lens RPC-01 — credit not taken or not returned for something that costs
resources, per level and per layer. A direct object is the purest instance: it
takes no credit because it is declared to weigh nothing.

## Hypothesis

`sendDirectObject` is never metered, so nothing bounds a zero-copy producer
against a stalled consumer. Refuted if the window reached it after all, or if the
codec path turned out no better — which is what the first four arms nearly said.

## Before

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

Probe: `packages/core/rpc_dart/.dart_tool/probe/b106_zero_copy_backpressure.dart`

**CONFIRMED, and only the last two rows confirm it.** The first four say both
paths run away equally, which is the opposite conclusion — and would have been
the round's answer had it stopped there, because the library does not throttle
producers by decision (`checked/C-19`), so "the producer got ahead" is not
evidence about metering at all.

Shrinking the window 64-fold moves the codec path 32x and moves zero-copy not at
all. That is what separates *unmetered* from *metered with a generous bound*.

## Mechanism

`bufferedBytes` is 0 for a `directPayload` and `sendDirectObject` never calls
`_fc.tryConsume` — it claims the ending and sends. The direct channel's `send` is
an immediate `add`. So every ledger the window is kept in reads zero for a
message the handler minted, and the lead's "a pointer" holds only for an object
the process already retains.

## After

n/a — nothing changed. See below.

## Canary

n/a for a fix. The bench's equivalent is the window arm: it is the ablation,
applied to the LIMIT rather than to a guard, and it is what makes the negative
rows mean something.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant. Nothing in `lib/` changed.

## Not fixed

**All of it, and this one is the owner's.** The sketch says to meter direct
objects and let `sendDirectObject` park on credit "like `sendMessage`". Both
halves are decisions rather than repairs:

- **A nominal weight per object is new public policy.** There is no honest byte
  count for an arbitrary Dart object, so the knob would be a fiction the
  operator has to size — and `RpcSecurityPolicy` carries an explicit warning
  against adding a field nothing enforces, which is the same trap from the other
  end.
- **Parking on credit reverses a decision already taken twice.** Round 208 chose
  to refuse a stalled call rather than pause the producer, and round 214 withdrew
  B-15 when it would have restored throttling; `checked/C-19` records both. A
  round that makes `sendDirectObject` park is overturning that for one path
  without being asked.

So B-106 stays open with the discriminating numbers in it, which is what makes
the decision cheap: the choice is between a nominal weight, an event ceiling, and
documenting that zero-copy means no backpressure.

**The isolate half is untouched.** `supportsZeroCopy => true` while every object
is deep-copied through `SendPort` — the lead's second question, not measured.

**And a second defect was measured on the way past, filed as B-195.** The codec
path's window is engaged (32x between the two window sizes) and an order of
magnitude looser than its own number: 185 MiB retained at a 4 MiB window. The
policy field's doc promises exactly what these rows disprove. It was this round's
CONTROL, not its subject, so it is a lead rather than a finding here.

## Links

Lens RPC-01. Bench P-135 (new). Lead B-106 (open, deferred to an owner decision).
New lead B-195. `checked/C-19` is the decision both halves of the sketch would
reverse; P-05 is the bench that recorded it.
