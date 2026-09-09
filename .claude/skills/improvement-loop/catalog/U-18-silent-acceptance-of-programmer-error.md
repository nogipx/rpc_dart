---
pack: core
applies: everywhere.
breaks: data loss, acting on the wrong object.
status: confirmed
---

# U-18 — Silent acceptance of a programmer error

## Shape

A map write that overwrites the previous value; a mismatch nobody rejects; an
identifier issued twice.

## Detector

Assignments into shared collections with no existence check; id issuance that
outlives a component restart.

## Ask

What happens when two different objects claim the same key?

## Evidence

Ids restarting after a reconnect made a dead operation's teardown half-close a
LIVE one; both obvious fixes failed.
