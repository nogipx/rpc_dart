---
pack: core
applies: anywhere comments outlive refactorings.
breaks: anything, usually silently — the justification also shields the ordinary path.
status: confirmed
---

# U-01 — A comment justifying deliberateness

## Shape

A comment explains why a branch behaves oddly, and describes a pathological
actor while doing so.

## Detector

Grep comments with "deliberately", "otherwise", "instead of", "rather than"
that describe behaviour rather than implementation; then read the branch they
guard.

## Ask

Does the stated justification cover EVERY case that reaches this code, or only
the one the comment names?

## Evidence

A justification about "a handler that ignores its own stream" also covered the
async preamble of ANY handler: ordinary code ran with no backpressure at all.
