---
pack: core
applies: any project with more than one build target.
breaks: anything, and usually crudely — nobody has checked these paths.
status: confirmed
---

# U-03 — A target nobody runs

> [Catalog](CATALOG.md) · instantiate before use:
> [lens-derivation](../methods/lens-derivation.md) · schema:
> [specs/lens.md](../specs/lens.md)

**Green on the main target does not mean green.** If a target cannot be run
because there is nothing to host it, that is a missing example app, not a fact
about the world.

## Shape

Code the main gate never executes: another compiler, another runtime, a native
layer, a device, a generator.

## Detector

The target list in the project's `config.md` against what the gate actually
runs.

## Ask

Which of these was never executed, only read or compiled?

## Evidence

The order is strict — **reading < compiling < running**. Reading let a report
through a function that does nothing after boot; compiling did not catch a 30 s
load stall; running showed that a page with no base URL cannot fetch its own
module.
