---
status: open
round: 595
commit: 1d16586c
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/stream_buffer_ledger.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: P-211
reason: "cost — round 595 bounded un-consumed request bytes per connection at the connection window, in two layers that count separately, so the true ceiling is twice the window; zero-copy payloads weigh 0 bytes and pass under it; and the other channels' pause contract (IRpcChannel's example, isolate, wasm) is unswept. Split out of B-138 when it closed"
---

# B-225 — what the connection total does not see

## What round 595 left, three items

1. **Two layers, two counters.** The transport ledger counts what it routes into
   per-stream controllers (bidi, server-stream); the pipeline budget counts the
   client-stream sinks and the pre-bind lists. Each is capped at the connection
   window, so a peer filling both holds up to twice it. Measured only per layer:
   `4093` messages (64 MiB) for 16 client-streams and for 16 bidi streams. Not
   measured: a mix.
2. **Zero-copy weighs nothing.** `bufferedBytes` is 0 for a `directPayload`, so
   neither total sees it; only the per-stream EVENT ceiling bounds such a stream,
   and that multiplies by the stream count. Zero-copy is in-process
   (`memoryPair`), so the peer is the same program — reachability first.
   Round 600 adds the connection-wide side: with NO listener on `incomingMessages`,
   `BufferedBroadcastController` holds up to 4096 direct objects of any size
   (`+376 MiB` for 400 x 1 MiB); with a consuming listener, `+6 MiB`.
3. **The pause contract on the other channels.** B-138's first half (round 534)
   made the websocket channel forward pause; `IRpcChannel`'s own documented
   example, the isolate channel and the wasm channel were never checked
   (RPC-08's shape).

## Not in the way of anything

Nothing here is a regression; each item is a remaining edge of a bound that did
not exist before round 594.

## Owner decision

—
