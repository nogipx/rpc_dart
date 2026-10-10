---
across: transport
test: packages/test/rpc_dart_conformance/test/i10_metadata_stays_with_its_origin_test.dart
severity: S1
---

# I-10 — metadata stays with its origin

## Statement

Call metadata is never sent to an origin other than the one dialed: redirects,
proxies.
