---
refines: U-18
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/**]
applies: identifiers are issued locally and outlive a reconnect
breaks: data loss on a live call.
applied: []
status: confirmed (round 100, off-journal)
---

# RPC-03 — Stream ids that outlive a reconnect

## Shape

The id manager starts numbering from scratch while operations issued before the
break are still alive.

## Detector

`RpcStreamIdManager`, `resumeAfter`, `lastIssuedId`,
`RpcChannelTransport.resumeStreamIdsAfter`, `lastIssuedStreamId`.

## Ask

Can tearing down a dead operation close a live one that holds the same id?

## Evidence

A dead call's teardown half-closed a LIVE one; both obvious fixes failed.
