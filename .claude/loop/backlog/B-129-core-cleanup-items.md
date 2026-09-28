---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart, packages/core/rpc_dart/lib/src/endpoint/caller_endpoint.dart, packages/core/rpc_dart/lib/src/endpoint/responder_endpoint.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/rpc/transports/in_memory_transport.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart, packages/core/rpc_dart/lib/src/core/protocol.dart, packages/core/rpc_dart/lib/src/codec/special_cbor.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-129 — core: dead code, misleading docs and duplicated helpers

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Twelve hygiene items: an unused parameter, no-op branches, try/throw/catch around a bool, redundant checks, merged doc comments, a factory that looks like a type, eight copies of one policy getter, a pinned last payload, payloads logged verbatim, a wrong dart2js claim.

## The shape

1. `responder_streams.dart:325-360` — `takeClientBufferedMessages(markEndOfStream:)`
   is never passed true any more; the doc line is duplicated.
2. `base_processor.dart:733-740` — `if (!_initialMetadataSent)` in `sendError` only
   logs and sets a flag.
3. `base_endpoint.dart:213-220` — `start()`/`stop()` only log.
4. `caller_endpoint.dart`/`responder_endpoint.dart` `_validate*Transport` — a
   try/throw/catch/rethrow around a bool getter.
5. `security_policy.dart:427-434` — `isValidHeaderName` re-checks CR/LF/NUL,
   already covered by `unit <= 0x20`.
6. `frame_multiplexed_channel.dart:281-301` — the doc comments of `_refuseMetadata`
   and `_maxMalformedMetadataFrames` are merged into one block.
7. `in_memory_transport.dart` — `RpcInMemoryTransport` is an abstract final class
   with a static `pair`, not a type; the endpoint error texts present it as one,
   and `rpc_notify` tests `transport is RpcInMemoryTransport` (always false —
   outside core, noted for B-10's owners).
8. `responder_pipeline.dart:118-273, 2204-2208`, `base_processor.dart:44-47`,
   `_trailerMessageCap` — one "policy of this transport or the default" helper
   written eight times.
9. `responder_streams.dart:250` — `lastPayloadMessage` is updated on every frame
   of a bidi/server-stream call and pins the latest payload for the call's life;
   it is only needed before bind.
10. `server/responder.dart`, `client/caller.dart` — internal-level logs interpolate
    `$request`/`$response`/`${rpcMessage.payload}`, putting payload data into
    logs despite the redaction machinery.
11. `protocol.dart:141` claims `<< 24` is a signed shift on dart2js; dart2js
    compiles `<<` and `|` to `(a op b) >>> 0` (unsigned). The `getUint32` code is
    fine; the comment is wrong and contradicts `special_cbor.dart:359`, which keeps
    `<< 24`.
12. `unary/caller.dart:226` and similar — `(message) async {...}` listeners with no
    await allocate a Future per message; `rate_limiter.dart` `_statusResourceExhausted`.
13. `resilience/retry_interceptor.dart:124` — the backoff `Future.delayed` ignores
    the call's cancellation token; a cancel during backoff waits up to `maxDelay`.
14. `core/security_policy.dart:474-507` — `validateMetadata` never enforces
    `maxMetadataBytes` in total (128 headers x 8 KiB fit); only the channel frame
    decoder bounds it, so the HTTP transports do not.
15. `core/metadata.dart:92, 471-484` — `forClientRequest` caps each token at 128
    characters while the policy's path limit is 1024, so a long dotted service
    name the server accepts cannot be called.
16. `rpc/streams/unary/caller.dart:292` — `break` after the first decoded response
    silently drops any further messages in the chunk; the "extra response"
    warning below it is unreachable.
17. `endpoint/responder_pipeline.dart:2180` — `context.getHeader('x-trace-id')`,
    a literal where `RpcHeaders.xTraceId` is used everywhere else;
    `responder_endpoint.dart` `setLogController` swaps `_log` but the ping handler
    and processors keep the scope captured at construction.
18. `core/parser.dart:151-157, 211-220` — a header-parse failure is logged at error
    twice (inner catch, then `call`).

## Why it matters

Each is small; together they are the reading cost of the files above.

## Witness a round would build

None — read and delete.

## Fix sketch

One cleanup commit per file group.

## Owner decision

—
