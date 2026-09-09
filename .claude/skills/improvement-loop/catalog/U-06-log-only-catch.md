---
pack: core
applies: everywhere.
breaks: silent data loss.
status: confirmed
---

# U-06 — A log-only `catch` on the path to success

> [Catalog](CATALOG.md) · instantiate before use:
> [lens-derivation](../methods/lens-derivation.md) · schema:
> [specs/lens.md](../specs/lens.md)

Two consequences of that fix:

- fix at the point that RENDERS THE VERDICT, not at every failure site: one edit
  closed all four call shapes;
- turning it into a `throw` instead looked cleaner and was wrong, because one
  implementation calls the send and the completion inside a single `try`, so a
  throw skips the completion and hangs the caller. **Check every call site
  before turning a swallow into a throw.**

## Shape

`catch { log }`, and then an unconditional success signal later in the same
lifecycle.

## Detector

Grep catch blocks whose only action is a logger call; read what the code does
AFTERWARDS.

## Ask

Can the caller draw a wrong conclusion from what follows the swallow?

## Evidence

A failed send was logged while the stream ended with a success status: an item
that never left the process arrived at the receiver as a stream it is simply not
in.
