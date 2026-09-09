---
pack: async-io
applies: there is accounting of resources released when an operation completes.
breaks: a hang, unbounded growth, DoS.
status: confirmed
---

# U-07 — "Abort" became "continue"

> [Catalog](CATALOG.md) · instantiate before use:
> [lens-derivation](../methods/lens-derivation.md) · schema:
> [specs/lens.md](../specs/lens.md)

The checklist after such a fix: credit, slots, identifiers, timers AND the price.

A clean negative from the same place worth remembering: metadata frames were
outside flow control entirely, so the credit obligation did not apply to that
skip. Checked, not assumed.

## Shape

A fix that made a failure survivable: what used to tear everything down now
skips the bad part and lives on.

## Detector

The journal and the diff for replacements of "abort/close/throw" with
"skip/continue"; for each one, what the abort path used to do.

## Ask

What did the abort make UNNECESSARY that must now happen explicitly — credit, a
slot release, an id return, a timer? And what does an attack cost per unit now?

## Evidence

Skipping a frame did not return credit the sender had already charged itself:
the connection wedged on exactly the predicted refusal (an 8 MiB window with
2 MiB per refusal = the fourth). The same shape by price, a round later:
**1.8 MB of input -> 1050 MiB RSS and 81 s of CPU**, whereas aborting gave the
attacker exactly one attempt.
