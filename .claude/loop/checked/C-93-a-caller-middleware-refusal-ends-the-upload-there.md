---
round: 865
commit: 01ec5654
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
scope: one caller middleware throwing in processRequest on the second request of a client-stream and a bidi call, over a channel pair
---

# C-93 — a caller middleware refusal ends the upload there

A request the caller's own middleware rejects ends the upload at that
point on both upload shapes: the handler reads r0 and then
`RpcCancelledException`, never r2 or r3, and the caller's call fails with
the middleware's error. Bench
`../probes/P-332-a-caller-middleware-that-rejects-a-request.md`.

## Control

The middleware passing everything: the handler reads r0..r3 and DONE, both
calls OK.
