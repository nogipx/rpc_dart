---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/refused_streams_are_released.dart
round: 397
commit: 8e47a55b
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
status: valid
---

# P-84 — what a refused HTTP/2 stream leaves behind

## Why it exists

RPC-22 on the http2 responder: the refusal path is the one anyone reaches
without credentials, and its per-stream state is pruned only by a call the
pipeline makes for streams the pipeline knows about.

## Measures

`incomingStreams`, `streamSubscriptions`, `streamParsers` and `outgoingPumps`
from the server transport's own `health()`, plus `activeResponders` from the
endpoint's metrics, after 200 requests on ONE connection — and the `grpc-status`
the peer was told, per arm.

Drives the peer with `package:http2` directly rather than through
`RpcHttp2CallerTransport`, because the arms need malformed requests
(`:method: GET`, a gRPC prefix declaring 32 MiB) that a well-behaved caller will
not send.

## Two rebuilds, both worth keeping

1. **It read the counters after `conn.terminate()`.** That runs the transport's
   `close()`, which clears every map, so both arms said 0 and the bench was
   measuring its own teardown. The read now happens while the connection is
   open.
2. **Its "control" was refused too.** A POST with no body is rejected by the
   PIPELINE ("Request stream closed without payload"), so both arms came back
   `grpc-status 3` and there was no served arm. The `grpc-status` column was
   added for exactly this: an arm that never reached the path it names must not
   be able to read as a clean one.

## Control

`open, never ended` — 200 streams the peer never half-closes. They legitimately
stay live, and reading **200 / 200** is what proves these counters report
retention at all. Every other arm's zero is meaningless without it
(measurement.md item 8).

`streaming, mid-answer` (round 396) is the same job for the pump column: 200
server-streams that answered once and parked, so their writers are live and it
reads 200.

## The numbers (round 397)

Before the framing-violation site released its stream:

```
arm                      incoming  subs  parsers  pumps  responders  peer saw
streaming, mid-answer       200      0      0      200      200      (mid-response)
open, never ended           200    200      0        0        0      -
served (grpc-status 0)        0      0      0        0        0      grpc-status 0
half-closed, no body          0      0      0        0        0      grpc-status 3
refused (:method GET)         0      0      0        0        0      grpc-status 3
bad frame, half-closed        0      0      0        0        0      grpc-status 8
bad frame, still open       200    200    200      200        0      grpc-status 8
bad frame mid-upload          1      1      1        1        1      grpc-status 8
```

After: the last two arms read all zeros, every other arm unchanged.

**The PAIR is the measurement, not either row.** `bad frame, half-closed` and
`bad frame, still open` differ in one bit — whether the peer set END_STREAM —
and the server answers both identically. An arm on its own would have said
"refusals are clean" or "refusals leak" depending on which one was written.

## What it establishes, and what it does not

Establishes: a stream refused before the pipeline sees it releases its transport
state — at both refusal sites, and on whichever of the four endings the peer
chooses.

Does NOT drive the remaining refusal triggers (`validateMetadata`,
content-type, the 256-violation backstop), nor a peer that refuses to read its
own refusal. On that last one: the refusal is a trailers-only HEADERS frame and
HTTP/2 flow control covers DATA only, so a zero receive window will not park it
— that needs TCP-level backpressure.
