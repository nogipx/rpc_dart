---
across: transport
test: packages/test/rpc_dart_conformance/test/i3_memory_per_peer_test.dart
severity: S1
---

# I-3 — memory per peer is bounded

## Statement

Memory held for one connection stays within a bound derived from the
configured limits, whatever the peer sends or withholds: unfinished frames or
headers, pings, a paused read, many streams.
