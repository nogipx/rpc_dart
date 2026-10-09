---
across: transport
test: packages/test/rpc_dart_conformance/test/i1_every_call_ends_test.dart
severity: S1
---

# I-1 — every call ends

## Statement

A call of any shape ends, with a result or a status, within its deadline + 1 s,
on every transport, whatever the peer does: silent, slow, half-open, closes
mid-frame.
