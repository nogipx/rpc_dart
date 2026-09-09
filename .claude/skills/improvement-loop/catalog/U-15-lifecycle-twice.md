---
pack: core
applies: there are objects with an explicit lifecycle.
breaks: a leak, a hang, an orphaned resource.
status: confirmed
---

# U-15 — Drive the lifecycle twice

Related: **connection-level defects hide from tests that use one connection per
test.** One side killed its own connection after four calls with 74 tests green.
The missing test shape is "keep working on a single instance".

## Shape

An API called a second time: `close()` after `close()`, reconnecting, starting
after stopping, restarting.

## Detector

Enumerate the public lifecycle methods and drive each one twice, concurrently
included.

## Ask

Which state did not return to where it started after the first call?

## Evidence

Five defects in five rounds. One flag meaning both "closed" and "disconnected"
made reconnecting usable exactly once.
