---
pack: core
applies: there is a wrapper around a third-party library.
breaks: a hang, a leak, data loss.
status: confirmed
---

# U-04 — An unregistered extension point of a dependency

Nothing looks wrong in your own code: **the defect has the shape of an absence.**

## Shape

The dependency offers a callback or a setter, and the wrapper never sets it.

## Detector

Enumerate the dependency's public API for callbacks, setters and `on*` fields;
for each one, find where your code registers it.

## Ask

Which event do we therefore never learn about?

## Evidence

The only way to learn the peer had disconnected was subscribed by nobody — a
cancelled call ran forever.
