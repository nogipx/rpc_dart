---
status: decided by owner (round 445)
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_http/lib/**]
probe: —
reason: cost — split out of B-70 item 19; confirmed for the http2 HEADERS path, and the HTTP/1.1 half is unproven
---

# B-86 — the end flag is gated on the status on the DATA path only

http2's DATA path will not end a stream before the status is known:

```dart
// :1418
isEndOfStream: message.endStream && i == messages.length - 1 && statusKnown
```

above a comment naming the silent data loss it prevents and the commit that
added `_statusReceived`. The HEADERS path (`:1346`) is a bare
`isEndOfStream: message.endStream`.

**Confirmed for http2. The HTTP/1.1 half is UNPROVEN** and the original sweep
overstated it — recorded here so nobody re-derives the stronger claim. For
HTTP/1.1 the caller always emits a terminal message: a synthesised grpc-status
from the HTTP code (`:380`) or the parsed trailer set (`:449`), and only
`grpc-status`/`grpc-message` reach that set (`:420`). So an empty trailer would
end the stream with no status — **whether that is REACHABLE was never
established.**

This is the same damage class as B-62 and round 429's truncated-stream work: a
stream that ends clean with no status is indistinguishable to the consumer from
a server that finished, so the caller gets a short read reported as success.
P-97 is the bench for reading that ending and should be reused rather than
rebuilt — repeat its control first.

The round's order: establish reachability on the http2 HEADERS path first
(cheaper, confirmed), and treat HTTP/1.1 as a second question rather than
assuming the sweep's version of it.

## Owner decision

**Take it. Reachability on the http2 HEADERS path first; then put the check in
CORE, at the consumer boundary, once.**

Order is the lead's own and is not negotiable — establish reachability before
writing anything.

If it is reachable, do not add a third `statusKnown` clause to a third end-flag
expression. The processor is the one place that knows BOTH facts — the stream
ended, and no status was ever seen — so a clean end with no status becomes an
error there, for every transport at once. That also covers the HTTP/1.1 half
without first having to prove the empty-trailer path is reachable, which is the
question the sweep overstated.

This turns a silent success into an error. That is the point — today a short
read is reported as success — but it needs an explicit CHANGELOG line, because
a consumer that quietly tolerates truncation starts failing.

Reuse P-97 for reading the ending; repeat its control first.
