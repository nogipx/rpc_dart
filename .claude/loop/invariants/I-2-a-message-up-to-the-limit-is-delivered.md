---
across: transport
test: packages/test/rpc_dart_conformance/test/i2_message_up_to_the_limit_test.dart
severity: S1
---

# I-2 — a message up to the limit is delivered

## Statement

Under the default policy, any message up to `maxMessageSize` is delivered in
both directions on every transport, whether the receiver is reading or paused.
