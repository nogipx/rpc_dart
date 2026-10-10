---
across: transport
test: packages/test/rpc_dart_conformance/test/i8_decode_is_bounded_test.dart
severity: S1
---

# I-8 — pre-auth input costs a bounded multiple of its bytes

## Statement

Decoding before authentication (CBOR, gzip) allocates at most K x the wire
size. K is set by `RpcSecurityPolicy.maxDecodedItems` (B-275, round 803).
