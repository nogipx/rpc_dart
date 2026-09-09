---
pack: core
applies: there are decorators, proxies or adapters around the main type.
breaks: a silent disabling of a protection — the worst kind, because the tests stay green.
status: confirmed
---

# U-05 — A capability hidden by a wrapper

## Shape

Behaviour is switched on by an `is IFoo` check, and the object arrives wrapped
in a decorator that does not forward the interface.

## Detector

Grep type checks and casts on capability interfaces; for each one, walk the
wrapper chain from construction to the check site.

## Ask

Does the interface survive as far as the check, through every wrapper on the
way?

## Evidence

200 of 200 streams got through against a ceiling of 3: the ceiling worked, the
capability check did not.
