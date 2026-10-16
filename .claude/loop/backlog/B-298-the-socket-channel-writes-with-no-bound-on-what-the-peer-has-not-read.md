---
status: closed (round 881)
round: 881
commit: ed6f6293
paths: [packages/transport/rpc_dart_socket/lib/src/rpc_socket_channel.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
probe: packages/transport/rpc_dart_socket/.dart_tool/probe/r881_deaf_peer_write_backlog.dart (P-336)
reason: risk — a hypothesis from reading the code in round 880; measured and fixed for the socket channel in round 881, the websocket half is B-300
---

# B-298 — the socket channel writes with no bound on what the peer has not read

`RpcSocketChannel.send` calls `Socket.add` and returns. Its doc says that
rpc_dart's flow control is what bounds the bytes in flight. Flow control
covers DATA on a stream. It does not cover a call that ends at once with
only metadata and a trailer.

Unmeasured question: suppose a peer stops reading at the TCP level and
keeps starting calls that the server answers immediately. Does
dart:io's write queue on the server grow with every answer? The channel's
read side keeps reading, because nothing ties it to the write backlog.
Round 400 (P-86) showed that http2 is bounded here by its dependency's own
read backpressure. Round 713 fixed the websocket version of this for pings
only. The websocket channel's doc says it has the same design, so the
question applies there too.

I-3 is the invariant at stake ("a paused read, many streams").

## Next step

Measure the server process's footprint against the number of answered
calls. Use a TCP-level deaf peer, as in P-86. Compare with a control peer
that reads.

## Owner decision

—
