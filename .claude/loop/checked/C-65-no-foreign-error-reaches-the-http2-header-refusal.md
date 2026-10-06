---
round: 662
commit: d787becb
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart]
scope: [rpc_dart_http2 responder, header refusal path]
---

# C-65 — no foreign error reaches the http2 header refusal

B-191 read `_answerRejectedStream` as putting `toString()` of any thrown error on
the wire, bypassing `wireStatusFor`. The formatting is real; what can REACH it is
not. Every throw inside `_handleIncomingMessage`'s try, swept:

- `_handleIncomingHeaders`: `ArgumentError.value(':method', ...)` (ours, a fixed
  message); `http2HeadersToRpcMetadata` throws only `RpcMetadataViolation`
  (`String.fromCharCodes` does not throw); `validateMetadata` likewise, and
  `RpcSecurityPolicy` is `final`, so no user override can throw something else;
  `_emit` adds to controllers whose listener throws go to the zone, not to `add`.
- `_handleIncomingData` catches its own errors and answers through
  `_answerFramingViolation`, which already uses `wireStatusFor`.

Driven from a raw http2 peer (`packages/transport/rpc_dart_http2/.dart_tool/probe/b191_rejected_stream_text.dart`):

```
POST    grpc-status=0
GET     grpc-status=3  gRPC requires POST; this request used a different HTTP method
BIGHDR  grpc-status=3  Invalid metadata header value for: x-big
NHDRS   grpc-status=3  Too many metadata headers: more than 128
```

Every reachable answer is a deliberate INVALID_ARGUMENT message of ours.

## Control

A foreign `StateError('db password=hunter2')` thrown in place inside
`_handleIncomingHeaders` reached the wire on three arms:
`grpc-status=13 grpc-message=Request rejected: Bad state: db password=hunter2`.
So the bench sees the leak the lead describes; nothing in the shipped code
produces one. A new throw site inside that try would -- the formatting is the
thing to re-check if the sweep above ages.
