---
status: open
round: 881
commit: ed6f6293
paths: [packages/transport/rpc_dart_http2/lib/**]
probe: —
reason: bench — needs a raw HTTP/2 peer; a package:http2 client cannot open streams past MAX_CONCURRENT_STREAMS while it reads nothing
rank: 3
---

# B-301 — the http2 server may read on while its writes queue

Round 881 measured the socket and websocket servers taking every call from a
peer that never reads (P-336; socket fixed, websocket B-300). The matrix row
`I-3 a peer that never reads is not answered without bound` skips http2.

Hypothesis from reading package:http2 3.1.0, not measured: no read pause is
tied to the frame writer's buffer. `wouldBuffer` is consulted in
`flowcontrol/connection_queues.dart` (outgoing) and
`flowcontrol/stream_queues.dart:342` (one stream's incoming), and no code
pauses the frame reader. A trailers-only answer is HEADERS, outside flow
control, so a peer that keeps opening streams and reads nothing would grow the
outgoing queue.

Why the matrix cannot drive it yet: the conforming client the rig has
(package:http2 over a relay, as in P-86) cannot see a stream retire while it
reads nothing, so it stops at the server's MAX_CONCURRENT_STREAMS
(maxActiveStreams, 4096 by default). The bound it meets is the many-streams
one. A raw peer writing HPACK HEADERS frames itself, past that number, is the
bench.

## Owner decision

—
