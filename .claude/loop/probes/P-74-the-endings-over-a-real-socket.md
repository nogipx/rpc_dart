---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/bidi_endings_over_socket.dart
round: 384
commit: 69d24a76
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-74 — C-41's seven endings, over a real socket and over a round trip

## Why it exists

C-41 settled bidi's endings on `RpcChannelTransport.pair()`. A pair flattens
anything the size of a round trip (P-58), and a teardown racing an in-flight
frame is exactly that. This asks the same seven questions where the caller's
decision and the server's reaction are separated by a link.

## Measures

Per arm, per scale, on ONE connection: the responder's `openStreams` and
`activeResponders`, the handler's live count, and the transport's
`activeStreams` / `streamControllers` / `statusSeen` on BOTH sides — nine
counters, six of them through the shipped wrapper's `health()`.

Then two things P-63 does not have:

- **a unary call on the same connection after every scale.** An ending that
  WEDGES a connection leaves every counter at zero, so a matrix of zeros cannot
  see it. This column is what B-53 was eventually caught by, one transport over.
- **duplex cases**: 30 messages each way with ordering checked, and 8
  concurrent bidi calls each with its own tagged sequence, so cross-talk between
  streams shows up as a wrong tag rather than a missing one.

Two links: the socket direct, and the same socket through a Dart TCP relay that
holds every chunk 25 ms each way. The relay rather than toxiproxy because it
needs no container; equal-duration timers fire in schedule order, so byte order
is preserved.

**Flow control's three counters per side are NOT here**, and that is the cost of
measuring the shipped path: `RpcWebSocketCallerTransport` and
`RpcWebSocketResponderTransport` forward `health()` but not
`flowControlStateSizes`. Those live on the core copy (P-63) and the leak they
would show is core's, not this transport's.

## Control

The unary arm, run through the same endpoints on the same connection in the same
run: a counter that climbs for bidi and not for unary belongs to the shape.

And the deadline row is the sensitivity proof this bench would otherwise lack —
it is the one arm that reads NON-zero (5 / 14 / 14), so the instrument is
demonstrably able to report retention on these counters at these scales.

## The numbers (round 384)

Every arm zero and `usable` on both links except `deadline`, which holds
5 / 14 / 14 direct and 5 / 7 / 7 through the relay, and clears at ~2.2 s. Full
table in `../rounds/384-the-sibling-told-the-peer-and-this-one-did-not.md`;
`fullDuplex` 30/30 order preserved, `concurrent` 8 of 8 clean on both links.

## What it establishes, and what it does not

Establishes: over a real websocket, with and without a round trip, no bidi
ending retains state on these counters, ordering holds in full duplex, eight
concurrent calls do not cross-talk, and the connection stays usable after every
ending.

Does not cover 100 ms+ links, packet loss, coalescing, a connection that DROPS
mid-call, dart2js, or RSS. And the `deadline` row is bounded retention by
design, not a clean zero — read it against `_reclaimGrace`.
