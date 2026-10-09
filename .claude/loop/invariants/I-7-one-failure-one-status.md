---
across: transport
test: packages/test/rpc_dart_conformance/test/i7_one_failure_one_status_test.dart
severity: S2
---

# I-7 — one failure, one status

## Statement

The same failure gives the same status code on every transport: deadline ->
DEADLINE_EXCEEDED, oversize -> RESOURCE_EXHAUSTED, dead peer -> UNAVAILABLE.
