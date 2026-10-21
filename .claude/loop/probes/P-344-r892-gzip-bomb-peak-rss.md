---
file: packages/core/rpc_dart/.dart_tool/probe/r892_gzip/probe.dart
round: 892
commit: 423913f4
paths: [packages/core/rpc_dart/lib/src/core/compression_gzip_io.dart]
status: valid
promoted:
---

# P-344 — r892 gzip bomb peak rss

## Measures

`rpcGzipDecompress` on a gzip of 1 GiB of zeros (1019 KiB on the wire) with
`maxOutputBytes` 16 MiB: outcome, time, and peak RSS growth over the call
(`ProcessInfo.maxRss` against the RSS before it). Two runs: refused in 5 ms,
+15 and +16 MiB.

## Control

The same meter on the unbounded path (`maxOutputBytes: null`) with a 64 MiB
bomb (63 KiB): decoded in 29-37 ms, +123 and +125 MiB. The meter sees full
residency when there is some.
