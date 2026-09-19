---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/malformed_reads_as_a_limit.dart
round: 412
commit: fdff6e57
paths: [packages/core/rpc_dart/lib/src/core/parser.dart, packages/core/rpc_dart/lib/src/core/protocol.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
status: valid
---

# P-93 — does malformed framing read as a resource limit?

## Why it exists

`_answerFramingViolation` classifies by TYPE and states the intent exactly:

> Every RpcException RpcMessageParser raises is a RESOURCE LIMIT ... Anything
> else reaching here is malformed framing, which is INTERNAL. Matched on the
> TYPE, never on message text.

`RpcException` is the BASE of the hierarchy, so the discriminator cannot mean
what the comment says. This asks what that costs on the wire.

## Measures

The `grpc-status` and `grpc-message` a peer receives, over a real socket.

## Control

**The two arms differ by five bytes and nothing else** — the same connection,
the same headers, the same method, one gRPC prefix apart:

```
limit      [0, 0x02, 0, 0, 0]   length 32 MiB against a 16 MiB cap
malformed  [2, 0, 0, 0, 4]      compression flag 2; only 0 and 1 exist
```

That is the whole design: with any other difference between them, a difference
in the answer would not be attributable to the classification.

## The numbers (round 412)

```
           before                                          after
limit      grpc-status  8  "...payload is too large..."     8
malformed  grpc-status  8  "Invalid compression flag ... 2" 13
```

RESOURCE_EXHAUSTED is retryable and INTERNAL is not, so before the fix a
structurally corrupt frame was answered *try again*.

The messages also lost their `RpcException: ` prefix, which is the second half
of the same change: the site now asks `wireStatusFor` instead of interpolating
`'$error'`, so an rpc_dart error forwards its message and a foreign one is
redacted.

## What it establishes, and what it does not

Establishes that a base-class check cannot carry a KIND, with the cost priced in
the one unit that matters — what the peer is told.

Does not drive the other three limit sites (`buffer overflow`, `decompressed too
large`, `too many messages in a chunk`); they share the parser path and the type
with the arm that is driven. Nor the decompression site, which is neither kind —
see round 412 for why it is INTERNAL.
