---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b97_phantom_post.dart
round: 488
commit: d3363ea4
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
status: valid
---

# P-127 — what a cancel puts on the HTTP/1.1 wire

## Why it exists

Core's cancellation falls back to a metadata frame when a transport implements
no `IRpcStreamReset`. On a wire format where one request IS the call, there is
no obvious place for such a frame to go — so the question is what this transport
does with it, and the instrument has to be on the SERVER, because the caller
reports a clean `RpcCancelledException` either way.

## The harness

A real responder behind a shelf handler that records every request path before
routing it. Two levels:

- through the endpoint, cancelling a token 100 ms into a 2 s handler;
- on the transport directly, for the window BEFORE the request fires — core
  releases the stream too quickly to reach it through an endpoint.

## The numbers (round 488)

```
                       requests reaching the server        caller sees
after the request fires
  cancel      before   2  [/Svc/slow, /Unknown/Unknown]    RpcCancelledException
  cancel      after    1  [/Svc/slow]                      RpcCancelledException
  no cancel            1  [/Svc/slow]                      the reply

before the request fires
  cancel      before   1  [/Unknown/Unknown]  body 0 bytes
  cancel      after    1  [/Svc/slow]         body 16 bytes
  no cancel            1  [/Svc/slow]         body 16 bytes
```

## Measures

Request paths recorded at the server, and the request body's byte length. Both
are on the far side of the wire, so they say what was SENT rather than what the
transport believes it did.

## Control

The same call with no cancel, which reads one request to the right path in both
levels. The caller's own outcome is NOT the control and cannot be: it reads
`RpcCancelledException` with the phantom request and without it.

## What it establishes, and what it does not

Establishes: a cancel cost a second request to a path nobody serves, and in the
pre-fire window it cost the REAL request — path and 16-byte body replaced.

Does NOT establish that cancellation now works. The server's handler runs to
completion in every arm; stopping it needs a real abort (B-140). This bench
cannot see that at all, since it counts requests rather than handler lifetimes.
