---
applies: everywhere; always enabled
damage classes: data loss, crash, hang, wrong result, security hole, unbounded growth, performance regression
shapes: U-01, U-02, U-03, U-04, U-05, U-06, U-12, U-14, U-15, U-17, U-18, U-19, U-20, U-21
contains: detectors/deliberate_comments.py — instances of U-01 (comments justifying deliberateness) across the tree
---

# core — what holds in any code

> [Packs](../PACKS.md) · schema: [specs/pack.md](../../specs/pack.md) · its
> shapes live in [catalog/](../../catalog/CATALOG.md)

The universal methods (`methods/`) are core too, but they are always read and so
do not live in a pack. Only what the script must be able to find by pack name
belongs here.
