---
file: packages/core/rpc_dart/.dart_tool/probe/metadata_weighs_characters.dart
round: 279
commit: 1ac04a24
paths: [packages/core/rpc_dart/lib/src/core/transport.dart, packages/core/rpc_dart/lib/src/core/buffered_broadcast.dart]
status: valid
---

# P-29 — what a queued header actually costs

P-21 extended with the shape P-21 does not have. P-21's arms are 8 headers x
8 KiB, where characters and cost nearly agree; this adds `thin`, many TINY
headers inside the same 64 KiB metadata cap, where `["h1","v1"]` weighs 4 and
retains an `RpcHeader` plus two Strings.

**One arm per process**, passed as an argument: `payload`, `fat`, or
`thin <headers>`.

## Measures

Frames ADMITTED, the wire bytes they carried, what `bufferedBytes` weighed them
at, and `maxRss` — plus which bound stopped the fill, which is the column that
names the defect.

Two things the bench had to get right, and both were wrong first:

- **The metadata is produced by DECODING a real wire frame**, never from
  literals. Dart canonicalises string literals, so headers built in-line are
  shared between frames and the retained cost collapses to nothing — the bench
  would have measured interning.
- **`maxRss`, not `currentRss`.** The GC moved `currentRss` by tens of MiB
  between arms and produced NEGATIVE growth (-28.7, -2.2, -29.5 MiB on
  identical fills). A high-water mark is monotonic, and it is why one arm per
  process is mandatory here.

## Control

The `payload` arm, unchanged from P-21: the same 64 KiB in `payload` rather than
in `metadata`. It is what says the harness's own overhead is ~2.3x, so the
metadata arm's 12.9x is the library and not the bench.

```
arm      headers  admitted   wire  weighed     RSS  ratio  stopped by
payload        -       256   16.0     16.0    37.3   2.3x  the byte bound
thin         500      4096   30.4     14.8   190.8  12.9x  the EVENT count  <-
thin        2000       943   30.4     16.0   186.4  11.7x  the byte bound
thin        5000       351   29.4     16.0   186.3  11.6x  the byte bound

after the fix
thin         500       468    3.5     16.0    20.8   1.3x  the byte bound
fat            -       253   15.8     15.9    21.8   1.4x  the byte bound
payload        -       256   16.0     16.0    39.9   2.5x  the byte bound
```

> **The plateau across three scales is the evidence, not any single row.**
> ~186 MiB retained whether 500, 2000 or 5000 headers per frame, against a
> 16 MiB bound: retention, not churn. And at 500 the byte bound did not engage
> at all — the event count stopped it, which is round 236's hole reopening one
> dimension over.
