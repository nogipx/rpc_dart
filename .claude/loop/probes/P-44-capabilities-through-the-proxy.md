---
file: packages/core/rpc_dart/.dart_tool/probe/capabilities_through_the_proxy.dart
round: 352
commit: 7d0881ad
paths: [packages/core/rpc_dart/lib/src/resilience/**, packages/core/rpc_dart/lib/src/endpoint/**]
status: valid
---

# P-44 — what the layers above lose to a transport wrapper

Builds the same endpoint twice over the same transport object — once directly,
once on `RpcClientConnection.transport` — and asks what each capability the
wrapper could hide is worth in EFFECT rather than in `is`. Add an arm by adding
an effect; the rig (`_viaProxy`) is three lines and works for any wrapper.

## Measures

Three numbers, each read from the library's own side:

- **policy** — the largest unary response the CALLER's `RpcMessageParser`
  accepts, which `_policyOf(transport)` bounds.
- **zerocopy** — whether a codec-free call is accepted at all, refused by
  `caller_pipeline.dart` when `supportsZeroCopy` is false.
- **flowctl** — `deferred` in the responder transport's own
  `flowControlStateSizes`, which is 1 exactly when the responder pipeline
  claimed metering for the stream.

## Control

One variable: whether the proxy sits between the endpoint and the transport.
Channel type, policy, contract and payload are identical between the two arms
of each pair.

```
effect     arm       result
policy     direct    20 MiB received
policy     proxy     gRPC frame buffer overflow: 20971533 bytes (max: 16777221)  <- before
policy     proxy     20 MiB received                                             <- after
zerocopy   direct    accepted, 3 bytes back
zerocopy   proxy     Invalid argument(s): Zero-copy requires a transport that... <- before
zerocopy   proxy     accepted, 3 bytes back                                      <- after
flowctl    direct    deferred=1
flowctl    proxy     deferred=0                                                  <- before
flowctl    proxy     deferred=1                                                  <- after
```

`max: 16777221` is 16 MiB plus the 5-byte message prefix — `const
RpcSecurityPolicy()`'s `effectiveMaxBufferedBytes`. The number identifies WHICH
policy the parser was built from, which is the whole point of measuring the
effect rather than the `is` check.

**Rebuilt once, and the first version is the instructive one.**
`RpcFrameMultiplexedChannel.pair()` carries its OWN copy of the policy and
bounds reassembly with it. Left at the default it refused the 20 MiB body with
`Incoming frame buffer overflow` — in BOTH arms, control included. A neighbouring
limit fired first and the bench said nothing about the proxy. Set every other
limit generously, and read WHICH limit the refusal names.
