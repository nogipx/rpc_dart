---
round: 782
class: metric
cost: one probe read as "the memory is released after ~100 s" while all 300 connections were still open and holding it
paths: [packages/transport/*/.dart_tool/probe/**, packages/core/*/.dart_tool/probe/**]
commit: 5db1dd59
status: active
---

# L-23 — rss falls while the memory is still held

## The rule

On macOS, `ProcessInfo.currentRss` of memory that sits untouched falls within
a minute or two, because the kernel compresses idle pages. A falling RSS is
not a release. Read the PEAK, and for anything held longer than ~30 s read
`footprint -p <pid>` (`phys_footprint` counts compressed pages) as well.

## What it cost

Round 782 held 300 unfinished request header blocks against a server. RSS
went +311 MiB at 15 s, +134 MiB at 75 s and +0 MiB at 105 s, with every
connection still open. `footprint` read 318 MB at 20 s and 318 MB at 110 s:
nothing had been freed.

## How to apply

A probe whose claim is "held" or "released" prints `footprint`'s
`phys_footprint` at the end of the window, not only RSS. On Linux, RSS does
not compress this way; swap still can, so read the peak there too.
