---
across: transport
test: packages/test/rpc_dart_conformance/test/i6_cancel_reaches_responder_test.dart
severity: S2
---

# I-6 — a cancel reaches the other side

## Statement

A caller's cancel ends the responder handler's token within 1 s on every
transport.
