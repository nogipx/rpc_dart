---
across: transport
test: packages/test/rpc_dart_conformance/test/i4_peer_cannot_crash_test.dart
severity: S1
---

# I-4 — a peer cannot crash the process

## Statement

Nothing a peer sends or omits produces an uncaught async error or ends the
process.
