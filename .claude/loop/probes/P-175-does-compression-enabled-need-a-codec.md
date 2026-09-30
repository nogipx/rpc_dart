---
file: packages/core/rpc_dart/.dart_tool/probe/compression_enabled_on_web.dart
round: 543
commit: b566bcb8
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/core/compression.dart]
status: valid
---

# P-175 — does `compressionEnabled: true` need a codec to be registered?

## Why it exists

A platform difference is the obvious way to ask this — dart2js has no built-in gzip — and it
is the wrong way. It needs a browser, it takes minutes, and it conflates "this fails on the
web" with "this fails because the registry is empty", which are different claims with
different fixes.

**The knob is the REGISTRY, not the platform.** `RpcGrpcCompression.unregister('gzip')` puts a
VM run into exactly the state dart2js ships in, so the question is answered in under a second
and the answer is about the mechanism rather than about a target.

## The harness

One unary echo call over `RpcChannelTransport.pair()`, with `compressionEnabled: true`, at
four registry states.

**A byte pipe, and not `memoryPair`.** The encoding header is only added when
`!transport.supportsZeroCopy`, so a zero-copy pair skips the whole path: the first version of
this probe used `memoryPair` and reported every arm healthy, including the one that was
broken. An arm that cannot reach the code under test reads exactly like a pass.

The third arm registers a small run-length codec — the remedy the library's own error message
names — which also proves the fix does not work by simply never compressing.

## The numbers (round 543)

```
  registry                         compressionEnabled: true
  as shipped (identity,gzip)       echoed 64 bytes
  gzip UNREGISTERED (identity)     RpcStatusException(12): Unsupported grpc-encoding: gzip
  a registered codec               echoed 64 bytes
  CONTROL compression off          echoed 64 bytes
```

Row 2 is the finding: with nothing but identity registered, `compressionEnabled: true` fails
EVERY call. After the fix it reads `echoed 64 bytes` and the request declares no encoding at
all.

## Measures

Whether the call completes, and what `grpc-encoding` the request declared — read off the
responder's inbound metadata, not inferred from the outcome. A call can fail for many reasons
and only one of them is the header.

## Control

**Row 4, the same call with compression OFF**, at both registry states. Without it a failure
in row 2 is equally consistent with the rig being broken, the transport pair being
misconfigured, or the echo contract being wrong.

**Row 1 against row 2** is the second control and the one that isolates the mechanism: the
same code, the same call, differing only in whether a codec is registered.

**Row 3** answers the question row 2 raises — is the documented remedy real? — and it is the
arm that would catch a fix that declares nothing ever.

## What it establishes, and what it does not

Establishes: the caller declared `grpc-encoding` from a constant while the adjacent line built
`grpc-accept-encoding` from the registry, so where no codec is registered it announced an
encoding neither side could perform and the peer refused the call. dart2js is that state by
construction.

Does NOT establish anything about compression RATIOS, which is what
`compression_never_makes_a_message_bigger_test` is for and which needs a real compressor.

Does NOT cover the responder's own response encoding: that path already asks the registry
through `selectResponseEncoding`, and this probe never varies it.
