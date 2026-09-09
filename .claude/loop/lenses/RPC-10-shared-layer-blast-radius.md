---
refines: U-11
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: several transports share parts of one layer
breaks: "wrong result: a claim about a fix's blast radius that the code does not support. It reached two commit messages, and through them the decision not to check the neighbour."
applied: []
status: confirmed (round 150, off-journal)
---

# RPC-10 — A shared layer does not reach every neighbour

## Shape

A fix in a shared layer looks like it covers every transport, while some of them
use only half of that layer.

## Detector

The map «which transport uses which layer»: `RpcChannelTransport` is shared by
the channel transports, but `RpcFrameMultiplexedChannel` is NOT used by isolate.

## Ask

Which packages ACTUALLY go through the class that changed?

## Evidence

The radius was overstated in two commits in a row.
