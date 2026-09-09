---
pack: async-io
applies: outbound data is validated by the same policy as inbound.
breaks: the reply is silently swallowed in exactly the strict configurations — the only ones where the path runs at all.
status: confirmed
---

# U-09 — A refusal must pass the rule it enforced

> [Catalog](CATALOG.md) · instantiate before use:
> [lens-derivation](../methods/lens-derivation.md) · schema:
> [specs/lens.md](../specs/lens.md)

Fixed by truncating the TEXT at the single place the reply is assembled: the
status survives, the text gives way.

## Shape

The error path emits its explanation back through the same validated channel
that has just refused.

## Detector

For every policy refusal, trace what the reply goes out through and which checks
it passes.

## Ask

Can the explanation violate the very limit being enforced?

## Evidence

The length of the explanation decided which status the client saw: a meaningful
code with a 70-character note arrived as a generic internal failure.
