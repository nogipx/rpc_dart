---
pack: refactor
applies: the package's public surface comes from a barrel that re-exports wholesale.
breaks: "a type nobody meant to publish becomes a compatibility promise, and the implementation starts depending on its own public API."
status: confirmed
---

# U-23 — Public by omission

> [Catalog](CATALOG.md) · instantiate before use:
> [lens-derivation](../methods/lens-derivation.md) · schema:
> [specs/lens.md](../specs/lens.md)

## Shape

The surface is not chosen. A barrel re-exports barrels, each re-exporting
everything declared in it, so a type is public because nobody wrote an
underscore. Machinery, half-finished helpers and whole SDK libraries arrive
alongside the API.

## Detector

1. Count the public top-level types reachable from the entry point.
2. For each candidate, grep who uses it OUTSIDE this package's implementation.
   That splits the list into machinery, API-for-extenders, and tests-only — and
   only the first is hideable.
3. **Check whether the implementation imports its own public barrel.** If it
   does, nothing can be narrowed until that stops.

Then: is an SDK library re-exported from the entry point?

## Ask

If this is hidden, whose build breaks — a user, a sibling package, or only a
test?

## Evidence

152 public types to 139 by hiding thirteen; no dependent package broke, and
the who-uses-it grep is why: three types that read as internals turned out to be
what every transport builds on.

**A barrel the implementation imports is load-bearing in both directions.**
Eleven implementation files imported the public entry point, so `hide` there was
not an export change but a deletion from their namespace: 78 errors, 7 inside
the library, in files the edit never touched. The fix is a second barrel —
everything the implementation may use, with no view on what is public — and it
is a prerequisite rather than a cleanup. One grep finds it before the edit; a
build break finds it after.

**Measure the blast radius before planning around it.** Two rounds deferred
removing an SDK re-export on the stated cost of "one import per affected file
across five packages". Measured: zero.
