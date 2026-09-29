---
status: open
round: 519 (measured inside B-127; split out by the owner in the round-540 review)
commit: 6659c0ee
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/contracts/context.dart]
probe: P-156
reason: "bench — a server stream arms NINE timers before any deadline exists. That is not the thing B-127 filed, it is what measuring B-127 found, and the owner split it out rather than let it close with the refuted arithmetic"
---

# B-210 — a server stream arms nine timers before any deadline exists

Split out of B-127 by the owner in the round-540 review. B-127 asked what a DEADLINE costs
and its arithmetic was refuted — 2 timers on unary, 5 on a server stream, not three. This is
the other number the same measurement produced, and it is about a call that has no deadline
at all.

Bench `../probes/P-156-how-many-timers-does-a-call-arm.md`.

**Nine, with no deadline set.** So the cost is not the deadline's: something arms nine timers
for every server-stream call regardless. B-127's own remainder — consolidating deadline
ownership — spans three layers and could not be designed from that measurement; this one may
be much simpler, because a timer nobody asked for has no trade to weigh.

## Why it matters

Per-call timer churn on a streaming path, and a number large enough that the reason for each
is worth knowing. Nine is also the kind of figure that hides a duplicate: round 519 counted
them, it did not attribute them.

## Witness a round would build

P-156's counting Zone, but attributing each creation to its stack rather than totalling them
— which is exactly what round 519 said it did NOT do, and why it declined the fix. Then one
arm per candidate site, ablated, to see which of the nine are the same bound expressed twice.

**The trap round 519 recorded**: build the endpoints INSIDE the counted zone. Its first run
built them outside, so every responder timer went uncounted and the deadline looked free at
`1.0 timers/call`.

## Owner decision

—
