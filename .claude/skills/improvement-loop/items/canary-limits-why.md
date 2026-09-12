# What paid for the byte-limits canary items

> [Items](ITEMS.md) · the operative list is
> [canary-limits.md](canary-limits.md), printed by `loop.py brief` after the
> universal [methods/canary.md](../methods/canary.md)

## A new limit raises the question "WHEN do I charge?"

Both neighbours of the right answer are usually wrong, so canary them as well.
The concurrency ceiling landed twice before it was right: charging at handler
ENTRY turned out to be a no-op against a burst (30 calls sailed past a ceiling
of 3, because nothing is running yet at the moment a batch is admitted), and
charging at stream ADMISSION was a denial of service (8 metadata-only frames
refused every call for 60 s). Only the middle works — the moment of dispatch.

> **The tests must fail DIFFERENTLY for each wrong choice.** If one canary
> takes down several witnesses and another takes down none, the design is not
> pinned.
