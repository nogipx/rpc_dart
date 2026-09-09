---
pack: async-io
applies: there are limits on the size of incoming data.
breaks: "information loss, the wrong error class: a repeatable error becomes unrepeatable."
status: confirmed
---

# U-08 — A happy-path limit on the error path

> [Catalog](CATALOG.md) · instantiate before use:
> [lens-derivation](../methods/lens-derivation.md) · schema:
> [specs/lens.md](../specs/lens.md)

## Shape

One boundary applies both to data about to be parsed and to the diagnosis of why
there is nothing to parse.

## Detector

Places where the error path reads or assembles data with the same code as the
success path.

## Ask

What is this boundary for? Bounding a decodable body and bounding an explanation
string are different jobs.

## Evidence

An error code from the other side was replaced by our own complaint about the
size of the page carrying it, even though the status was known BEFORE the read.
