---
pack: core
applies: always, from the second round on.
breaks: a security hole, unbounded growth.
status: confirmed
---

# U-02 — Attack your own fix

> [Catalog](CATALOG.md) · instantiate before use:
> [lens-derivation](../methods/lens-derivation.md) · schema:
> [specs/lens.md](../specs/lens.md)

Attack it not only in the same round but in the next one: a fresh fix reads
differently once it has left your head.

## Shape

A fresh boundary tested only against an honest participant.

## Detector

The last N rounds of the journal; for each fix, which values and keys in it are
controlled by someone else.

## Ask

What if the controlled VALUE is extreme? What if the controlled KEY names
something that does not exist?

## Evidence

Three findings in a row came from attacking the previous round's fix; one DoS
came from re-reading a knob shipped a round earlier.
