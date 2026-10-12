---
round: 864
commit: 01ec5654
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
scope: one responder middleware throwing in processResponse, unary, server stream and bidi over a channel pair; not a middleware that throws in processRequest
---

# C-92 — a responder middleware refusal ends the stream there

A response the responder's own middleware rejects ends the call at that
response with INTERNAL on every shape measured: unary ERROR 13, server
stream and bidi `ok0`, then ERROR 13, nothing after. The middleware runs
inside the handler's stream, so its throw becomes the stream's error and
the pump answers it, unlike a codec failure (round 862), which surfaced
only after the send. Bench
`../probes/P-331-a-responder-middleware-that-rejects-a-response.md`.

## Control

The middleware passing everything: unary OK, both streams all four items
and done.
