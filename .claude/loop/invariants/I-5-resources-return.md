---
across: transport
test: packages/test/rpc_dart_conformance/test/i5_resources_return_test.dart
severity: S1
---

# I-5 — resources return

## Statement

After every call has ended, active streams, handler slots, flow-control credit
and timers are back at their baseline.
