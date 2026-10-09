---
status: closed (round 460)
round: 460 — both halves measured; http2 FIXED in 447, HTTP/1.1 CLEAN
commit: 4ff4e346
paths: [packages/transport/rpc_dart_http/lib/**]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/missing_trailers.dart
reason: bench — what remains is whether an HTTP/1.1 response can end with no status at all, which needs its own arm on that transport's trailer path
---

# B-86 — the end flag is gated on the status on the DATA path only

## CLOSED (round 460). HTTP/1.1 is CLEAN — `checked/C-52`.

The remaining half is measured. A 200 with no `grpc-status` anywhere IS reachable —
the synthesised status covers non-2xx only, so the trailer set comes out empty —
and the consumer is told:

```
200, no grpc-status   status=14 "The stream closed before the peer sent a status"
200, grpc-status: 0   RETURNED "answer"    <- control
200, grpc-status: 5   status=5
```

**The difference from http2 is the NUMBER of terminal messages, not the empty
metadata this lead reasoned from.** http2 emitted two — the trailers frame with no
status, then a synthesised one carrying 14 — and the first closed the consumer.
HTTP/1.1 emits exactly one, so there is no ordering to lose.

## http2 half (round 447)

Measured (P-101) and fixed: a trailers frame ending the stream with no
grpc-status read **CLEAN END after 2 items, no error** — the ending closed the
consumer and the synthesised UNAVAILABLE arrived one message too late, which is
the DATA path's own documented failure on the path without its guard. The HEADERS
path now reads `_statusReceived` before setting the end flag.

**The owner's decision was REFUTED by measurement and is not what shipped.** It
said to put the check in core at the consumer boundary, once, for every transport,
on the reasoning that this would cover the unproven HTTP/1.1 half for free. Core
already raises: over `RpcChannelTransport`, an ending with no status gives
`RpcStatusException` in all three variants tried, with a status-trailer control
reading NO ERROR. So there was nothing to add there, the gap was http2-local, and
**the free HTTP/1.1 coverage was never available.**

So this lead stays OPEN with its scope reduced to HTTP/1.1, and the round did not
quietly claim it. The corrected version of the HTTP/1.1 claim is below and was
already weaker than the sweep's.

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
