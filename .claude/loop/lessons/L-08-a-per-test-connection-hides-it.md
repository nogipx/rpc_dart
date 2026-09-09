---
round: — (pre-201, off-journal; imported in the curate pass after 234)
class: fixture
cost: 74 green tests over a caller that killed its own connection after 4 calls; the shape that finds it is one loop
paths: [packages/transport/*/test/**, packages/core/rpc_dart/test/**]
commit: d9b96a67
status: active
---

# L-08 — A per-test connection cannot see a per-connection defect

`RpcHttp2CallerTransport.releaseStreamId` ended with `stream.sendData(...,
endStream: true)` on a stream whose request direction was already finished —
a DATA frame on a half-closed-local stream, which HTTP/2 forbids and
package:http2 answers by terminating **the whole connection**. Measured: 4 of 40
sequential unary calls, then `Connection is being forcefully terminated`, and 0
of 8 concurrent rounds; 40/40 and 8/8 after (29d4a7b8). **The suite was fully
green**, because every one of its 74 tests builds a fresh server and connection
and makes one or two calls.

**The reproduction is nothing clever: keep calling on the SAME connection.** Add
that shape to any transport suite — a loop of 40-60 sequential calls plus a few
concurrent rounds, on one connection, asserting the per-stream counters return
to zero.

Two traps it hit. The `try/catch` around the offending call never fired, because
package:http2 raises the violation asynchronously from the connection state
machine — a synchronous guard proves nothing there. And the failure LOOKS like a
server or network problem ("connection terminated"), so in the field it is
misattributed to the peer. The same one-shot blindness applies to recovery APIs:
see `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md`, where calling
`reconnect()` twice exposed three defects a single call could not.
