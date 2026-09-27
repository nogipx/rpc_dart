---
status: open
round: 456
commit: b5b5980f
paths: [packages/core/rpc_dart/lib/src/core/compression.dart, packages/core/rpc_dart/lib/src/rpc/streams/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/encoding_case_matters.dart
reason: bench — measured as a failure but NOT diagnosed; the claim "compression does not work" is too large to file on one arm
---

# B-91 — gzip does not round trip through the documented path

Found beside B-82 in round 456, and deliberately not folded into it: it is not
about case.

```
own caller, grpc-encoding=identity   OK saw:x
own caller, grpc-encoding=Identity   OK saw:x      (after round 456)
own caller, grpc-encoding=gzip       status=13 Internal server error
own caller, grpc-encoding=GZIP       status=13 Internal server error
```

Measured over real http2, `RpcHttp2Server` against `RpcHttp2CallerTransport`, with
the encoding set the supported way — a header on the call context, which is what
`_context?.getHeader(grpcEncoding)` reads.

**Both spellings fail identically**, so round 456's accessor cannot be the cause,
and it was failing the same way before that fix.

## What is already known

- `isSupported('gzip')` must be returning TRUE, because the caller throws
  UNIMPLEMENTED when it is false and no UNIMPLEMENTED was raised. That check reads
  `_codecs.containsKey`, so **a codec is registered** — this is not "gzip is
  missing".
- The server advertises `grpc-accept-encoding: identity,gzip` in the same process,
  consistent with the above.
- An unregistered codec gets a precise refusal: `nosuchcodec` answers
  UNIMPLEMENTED naming the supported set and the remedy. So the machinery for
  saying "no" works; this is a failure inside the yes path.

## Why the status makes it hard to read, which is half the lead

The failure is `INTERNAL: Internal server error` with NO `grpc-accept-encoding`
header — a default-deny that names nothing. L-10 records this exact trap: a
default-deny INTERNAL makes every cause look the same. **Expect to need a
responder-side log or an in-process arm; the wire will not tell you.**

The same opacity appeared on a flag/encoding contradiction (compression flag 1 with
`identity`), which is a related but separate question.

## The measurable questions, cheapest first

1. **Which side fails?** Compress on the caller, or decompress on the responder.
   An in-process arm — `compress` then `decompress` with the same encoding, no
   transport — answers it in one line and needs no server.
2. **Is it `maxOutputBytes`?** The parser bounds decompressed size from the
   policy, and a small default against gzip's expansion would produce exactly an
   opaque failure. `effectiveMaxBufferedBytes` is in the path.
3. **Does the RESPONSE direction differ from the request?** The responder may
   compress its reply with the negotiated encoding, so the failure could be on the
   way back rather than the way out.

## Do not file this as "compression is broken" until 1 answers

`rpc_dart_compression`'s own suite passes (25 tests), so the codec itself works in
isolation. Whatever this is, it is in the wiring between the registry, the policy
and the two stream layers — not in gzip.

## Owner decision

—
