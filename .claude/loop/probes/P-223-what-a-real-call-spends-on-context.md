---
file: packages/core/rpc_dart/.dart_tool/probe/b120_what_a_real_call_spends_on_context.dart
round: 621
commit: a8af9626
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/lib/src/core/metadata.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
status: valid (round 621)
---

# P-223 — what a real call spends on context

## Why it exists

B-120's remaining half: what building and copying `RpcContext` and validating
headers costs in the chain a REAL unary call builds, not a synthetic `with*`
chain.

## The harness

3000 sequential unary echo calls over `RpcChannelTransport.pair`, after 500 to
warm, sampled with the VM's own profiler through the VM service the probe opens
on itself. Run with `fvm dart --profiler`. It reports, for each function of
`RpcContext`, `RpcContextUtils`, `RpcMetadata`, `_RegExp`, `Map.from`,
`_uniqueToken` and `_sanitizeHeaders`, the share of samples with that function
anywhere on the stack.

## The numbers (round 621)

```
127.1 us per call, 281 samples
 29.2%  RpcContextUtils.withTracing
 28.1%  RpcContext._uniqueToken        (the token the owner kept, round 565)
  1.4%  RpcContext.withHeaders
  1.4%  RpcContext._
  1.1%  RpcContext._sanitizeHeaders
  0.7%  RpcMetadata._validateMethodToken
  0.7%  RpcMetadata.forClientRequest
  <=0.4% each: headers, forServerInitialResponse, withLog, _RegExp.hasMatch,
              withCancellation, withValue, forTrailer, _normalizeHeaderName
```

## Measures

The share of a real call spent on context construction and header validation.

## Control

`_uniqueToken`, whose cost is already established (P-149, P-179), shows up at
its known share, which is how the profile is read as trustworthy.
