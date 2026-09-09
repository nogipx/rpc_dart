---
pack: core
applies: anywhere there is asynchronous cleanup.
breaks: a hang, a resource leak.
status: confirmed
---

# U-17 — An unbounded wait and abandoned work

> [Catalog](CATALOG.md) · instantiate before use:
> [lens-derivation](../methods/lens-derivation.md) · schema:
> [specs/lens.md](../specs/lens.md)

## Shape

An `await` with no bound on a critical path (completion, teardown), and a
timeout that drops the WAIT but not the operation itself.

## Detector

Grep `await` on shutdown and cleanup paths; grep timeouts applied to operations
that hold a resource.

## Ask

What lives on after we stopped waiting?

## Evidence

One stuck callback holds its owner forever; a timeout releases the waiter while
the operation goes on holding what it held.
