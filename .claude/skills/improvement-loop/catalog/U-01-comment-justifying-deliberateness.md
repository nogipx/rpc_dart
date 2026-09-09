---
pack: core
applies: anywhere comments outlive refactorings.
breaks: anything, usually silently — the justification also shields the ordinary path.
status: confirmed
---

# U-01 — A comment justifying deliberateness

> [Catalog](CATALOG.md) · instantiate before use:
> [lens-derivation](../methods/lens-derivation.md) · schema:
> [specs/lens.md](../specs/lens.md)

## Shape

A comment explains why a branch behaves oddly, and describes a pathological
actor while doing so.

## Detector

The instance list is a grep, not a program:

    grep -rniE "deliberat|on purpose|intentional|by design|do not (change|remove)" <src>

Each hit is a LEAD — a claim about the code that nobody has re-checked. Verify
it against the implementation; a comment that is right costs one read, and one
that is wrong is a defect with a signpost on it.

Grep comments with "deliberately", "otherwise", "instead of", "rather than"
that describe behaviour rather than implementation; then read the branch they
guard.

## Ask

Does the stated justification cover EVERY case that reaches this code, or only
the one the comment names?

## Evidence

A justification about "a handler that ignores its own stream" also covered the
async preamble of ANY handler: ordinary code ran with no backpressure at all.
