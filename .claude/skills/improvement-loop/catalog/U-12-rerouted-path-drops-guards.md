---
pack: core
applies: anywhere there are idempotent wrappers around ordinary operations.
breaks: a doubled action, a broken invariant.
status: confirmed
---

# U-12 — A rerouted path drops the old one's guards

## Shape

Call A was replaced by call B, and A checked something B does not.

## Detector

Grep replacements of helpers whose name encodes a precondition
(`...IfNeeded`, `...Once`, `ensure...`, `tryX`) with their simpler siblings.

## Ask

What did A check that B does not?

## Evidence

Replacing a guarded helper produced an ordering in which two terminal messages
went out where everywhere else sends one.
