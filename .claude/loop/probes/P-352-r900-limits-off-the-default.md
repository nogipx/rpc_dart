---
file: packages/test/rpc_dart_conformance/.dart_tool/probe/r900_raised_limit/probe_test.dart
round: 900
commit: 4965f223
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
status: valid
promoted: no — CLEAN round; I-2 already covers the default limit, and the mismatch behaviour is HTTP/1.1's documented one
---

# P-352 — r900 limits off the default

## Measures

Through the conformance members (wasm left out: it runs only under
`test:wasm`), every call shape:

- `probe_test.dart`: both sides at the same `maxMessageLengthBytes` of 64 KiB,
  16 MiB and 32 MiB, a message of exactly that size each way.
  `+72`, all delivered.
- `mismatch_test.dart` (same directory): the receiver at 32 MiB, the sender
  at the default, a 20 MiB message. Request direction: delivered on all six
  members. Response direction: delivered on channel, http2, isolate, socket
  and websocket; http status 8, "Response exceeds the 16777216-byte limit;
  HTTP/1.1 cannot stream it", in all four shapes.

## Control

The 16 MiB row is I-2's own case and is green, so the method sees a delivered
message as delivered; the http refusal shows it sees a refusal.
