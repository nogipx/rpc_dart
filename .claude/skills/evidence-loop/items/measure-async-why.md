# What paid for the two-sided-protocol measurement items

> [Items](ITEMS.md) · the operative list is [measure-async.md](measure-async.md),
> printed by `loop.py brief` after the universal
> [methods/measurement.md](../methods/measurement.md)

## How to probe a matrix of limits

**Set every OTHER limit generously.** A tight message-size limit makes the frame
buffer trip first, and every row reads as REFUSED even though the field under
test was never asked: 8 rows out of 9 were refused by an inbound buffer
overflow. **A refusal is evidence only if it names the control under test.**

**When a probe shows exactly zero, check whether the mechanism could emit
anything at all.** A credit-return probe showed 0 for two independent reasons:
the length declared by the first frame swallowed the following ones as its own
payload, and a single sub-threshold credit never reaches the wire at all because
grants are batched at half the window. Zero looked clean and was not.

## When an observation contradicts the model

Instrument EVERY hop at once rather than arguing about which one is lying.

**A gap made of LATENCY vanishes on an in-memory pair.** Re-running an old probe
gave BOUNDED both with and without the fix, because the peer's grant arrived
first on a zero-latency pair. The defect was real; the bench had stopped seeing
it. **Ask what the gap under test is made of**: 20 ms of one-way latency brought
back 156.25 MiB against 4.05 MiB.
