---
pack: core
applies: there are observable resource counters.
breaks: unbounded growth.
status: confirmed
---

# U-20 — Leak accounting against a baseline

**If you are waiting for a drop to zero, first wait for the rise.**

## Shape

A metric that must return to zero after N iterations, and does not.

## Detector

Enumerate the live-object counters; run N cycles and compare against the start.

## Ask

Did EVERYTHING come back, or only what we were watching?

## Evidence

Polling straight for zero succeeds instantly on a counter that never rose.
