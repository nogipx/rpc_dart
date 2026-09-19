---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/refused_streams_are_released.dart
round: 395
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

`incomingStreams`, `streamSubscriptions` and `streamParsers` from the server
transport's own `health()`, after 200 requests on ONE connection — and the
`grpc-status` the peer was told, per arm.

Drives the peer with `package:http2` directly rather than through
`RpcHttp2CallerTransport`, because the arms need malformed requests
(`:method: GET`) that a well-behaved caller will not send.

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

## The numbers (round 395)

```
arm                      incomingStreams  streamSubscriptions  peer saw
open, never ended              200                200          -
half-closed, no body             0                  0          grpc-status 3
refused (:method GET)            0                  0          grpc-status 3
```

## What it establishes, and what it does not

Establishes: a stream refused before the pipeline sees it releases its transport
state anyway.

Does NOT count `_outgoingPumps` — `health()` does not expose it, so the pump's
fate is inferred from `releaseStreamId` removing it on the same line as
`_incomingStreams`, not measured. Nor does it drive the other refusal sites
(`validateMetadata`, content-type, the 256-violation backstop), nor a peer that
refuses to read its own refusal.
