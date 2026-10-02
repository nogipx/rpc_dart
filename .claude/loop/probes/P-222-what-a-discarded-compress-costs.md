---
file: packages/core/rpc_dart/.dart_tool/probe/b206_what_a_discarded_compress_costs.dart
round: 620
commit: 1e8bf772
paths: [packages/core/rpc_dart/lib/src/core/compression.dart, packages/core/rpc_dart/lib/src/core/compression_gzip_io.dart]
status: valid (round 620)
---

# P-222 — what a discarded compress costs

## Why it exists

B-206: `compressIfSmaller` compresses every payload and keeps the smaller, so a
payload sent plain still paid for a compress. How much?

## The harness

`compressIfSmaller(..., encoding: 'gzip')` on the dart:io codec, warmed, per call,
over random (incompressible) and repeating (compressible) payloads, with which
form was sent.

## The numbers (round 620)

```
          incompressible        compressible
before
  16 B     17.86 us  plain       16.79 us  plain
  64 B     20.41 us  plain       19.50 us  gzip
 256 B     27.96 us  plain       19.47 us  gzip
   1 KiB   36.35 us  plain       20.18 us  gzip
  16 KiB  141.03 us  plain       42.44 us  gzip
after (floor at gzip's 20-byte minimum, copies removed)
  16 B      0.11 us  plain        0.04 us  plain
  20 B      0.03 us  plain        0.03 us  plain
  21 B     19.12 us  plain       18.90 us  plain
  64 B     19.69 us  plain       18.45 us  gzip
  16 KiB  129.33 us  plain       40.12 us  gzip
```

About 17 us of every compress is fixed (zlib set-up), whatever the size.

## Measures

The CPU a compressed connection pays per message, and what it buys.

## Control

The form sent: identical before and after at every size.
