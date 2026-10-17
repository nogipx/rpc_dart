---
status: open
round: 884
commit: fea0d0c3
paths: [packages/transport/rpc_dart_http2/lib/**]
probe: P-339 — its `inproc` peer already opens windows in the matrix row's form
reason: risk — a suspicion from round 884's reading of package:http2, not measured
rank: 2
---

# B-303 — a peer granted window is the only bound on server stream data

Round 884 bounded what the http2 server reads while its writes are unsent,
which bounds answers to NEW calls. It does not bound DATA on streams already
open. A server-stream handler is paced by package:http2's per-stream
`StreamMessageQueueOut`, which reads the stream's send window only
(`flowcontrol/stream_queues.dart`), and the connection queue accepts whatever
the stream queues hand it. The send window is the PEER's number: a peer that
sets SETTINGS_INITIAL_WINDOW_SIZE and the connection window to 2^31 - 1 (the
matrix row's http2 peer does exactly that) and then reads nothing would let a
producing handler queue up to 2 GiB per stream in the server.

Before round 884 the same bytes would have sat in package:http2's
`ConnectionMessageQueueOut`; since then they sit in `Http2WriteBacklog`'s
controller. Neither location bounds them.

## Next step

Measure: P-339's raw peer with the windows opened, calling a server-stream
method that produces without end, never reading. Count what the handler
produced against a peer that reads. rpc_dart's own `flowControlWindowBytes`
may already cap it on the server's side; check where it charges (P-180)
before assuming it does not.

## Owner decision

—
