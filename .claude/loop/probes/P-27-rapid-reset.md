---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/rapid_reset.dart
round: 277
commit: dcf9d587
paths: [packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-27 — HTTP/2 Rapid Reset, and a raw h2 peer to reuse

A raw `package:http2` client that opens N streams against `RpcHttp2Server` and
terminates each one the instant the request is on the wire. It is the only bench
here that speaks HTTP/2 to the server WITHOUT rpc_dart's caller, so reuse it for
anything that needs frame-level control: GOAWAY handling, half-closed streams,
trailers-only responses.

Three arms: `reset`, `normal` (the control) and `diagnose`, which sends one
request and prints every response header.

## Measures

Handlers ENTERED, peak concurrency, and handlers still running at the end — all
counters inside the contract's own handler, on the server side of the wire.

## Control

`normal`: the same N streams, awaited instead of terminated. It answers two
questions at once — can this bench dispatch a handler at all, and does
`maxActiveStreams` bite.

```
arm      requests  handlers entered  peak concurrent
normal      200            4               4
reset       200            0               0
```

> **`diagnose` exists because both arms first read 0.** The request body was
> hand-built JSON and rpc_dart's wire format is CBOR, so every request came back
> `grpc-status: 13, grpc-message: Internal server error` — the redaction in
> `wireStatusFor`, which deliberately says nothing. One request with every
> header printed is what separates "the server refused me" from "the server
> answered and my bench cannot see it". Build the body with
> `codec.serialize(...)`; see `../lessons/L-10-a-hand-built-peer-needs-the-real-serializer.md`.
