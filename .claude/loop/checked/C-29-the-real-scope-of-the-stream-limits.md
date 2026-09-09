---
round: — (not re-measured)
commit: 8b98b2c5
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_http2/lib/**]
scope: [core, http2]
---

# C-29 — The real scope of the stream limits, and what to design against

Measured across rounds 137 and 139, off-journal; imported from private memory
after round 235. **Read this before describing any stream-exhaustion issue.**

**Responder endpoints are PER CONNECTION.** `RpcHttp2Server` builds one
`RpcResponderEndpoint` per socket, so `_respStreams` and
`RpcSecurityPolicy.maxActiveStreams` are per connection. Wedging one connection
does not affect another — verified with two connections, the untouched one kept
serving. **Do not call a stream-exhaustion issue "the server going offline"; an
earlier commit comment did and was wrong.**

**The cost that DOES cross connections is memory.** 2000 parked streams held
68.2 MB — about 33 KiB each. So a peer pins roughly `maxActiveStreams x 33 KiB`
per connection it opens: at the 4096 default, ~136 MB per connection. **That is
the number to design against, not the RESOURCE_EXHAUSTED symptom.**

**`halfOpenStreamTimeout` covers DISPATCH ONLY.** It reclaims a stream that never
dispatches (metadata with no request message). It does NOT reclaim one that
dispatches and then goes idle, and a peer gets that for ~30 extra bytes: one
request frame on a client-streaming method leaves the handler waiting forever on
a request stream that never half-closes. Measured `openStreams=8` indefinitely,
exactly as before the fix. Bounding it needs an idle-stream timeout, which
**cannot be safe by default** — a stream idle in both directions is also what a
legitimate rare-event subscription looks like. The limitation is asserted in
`test/endpoint/parked_stream_scope_test.dart` rather than hidden; a future idle
timeout must update that file.

**Peer-keyed bookkeeping in `RpcChannelTransport` — the audit is COMPLETE**
(e5ea6770, round 137). The transport keys several structures by a stream id the
PEER chooses, before the responder pipeline decides whether the id is a
legitimate stream at all. 400,000 metadata-only frames carrying `grpc-status` on
never-minted ids — frames the pipeline deliberately IGNORES as no-ops — left
`advertised: 4096` (at its cap) and `statusSeen: 399997`, on a connection that
had never carried a call. Fixed **by construction, not by a cap**: an entry is
recorded only for an id that has a per-stream controller, which is the only kind
it is ever read for. *A cap would have been the wrong tool* — evicting an entry
makes a COMPLETED call report as truncated. Every remaining structure there
(`_activeStreams`, `_streamControllers`, `_finishedStreams`, `_fc*`,
`_statusSeen`) is now bounded by our own traffic or by an explicit cap.

> **Whenever you add per-stream state to a transport, ask WHO chooses the key.**

## Control

Each claim has one. The per-connection scope was checked with a SECOND
connection that kept serving while the first was wedged. The 33 KiB figure comes
from a measured 2000-stream total rather than a per-stream estimate. And the
`statusSeen` count is the control for its own measurement: **RSS was not usable**
— the same 400k-frame comparison gave +10.3 MiB on one run and +2.9 MiB on the
next, so the counter had to be exposed first. Expose the counter before trusting
the memory.

## Test note

When a test holds client-side stream ids, give the CLIENT a larger
`maxActiveStreams` than the server — otherwise `createStream` throws a
`StateError` from the client's own ceiling, which says nothing about the server.
