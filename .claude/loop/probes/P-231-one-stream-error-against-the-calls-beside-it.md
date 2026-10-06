---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/one_bad_frame_fails_every_call.dart
round: 667
commit: ae33d09d
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-231 — one stream's error against the calls beside it

## Why it exists

Both endpoints read an error on `incomingMessages` as "the connection failed":
the responder answers every active call, `RpcClientConnection` retires the
transport. Three transports put errors about ONE stream there.

## The harness

Three files, each three slow unary calls in flight plus one offending stream,
with a control that sends the offending stream clean:

- `rpc_dart_http2/.dart_tool/probe/one_bad_frame_fails_every_call.dart` --
  `RpcHttp2Server`, the client sends a frame with compression flag 2.
- `rpc_dart/.dart_tool/probe/one_bad_stream_fails_every_call.dart` -- a channel
  pair, server policy `maxHeaders: 8`, the client sends 20 headers.
- `rpc_dart_http2/.dart_tool/probe/one_reset_retires_the_connection.dart` --
  `RpcClientConnection` over http2 to a raw peer that RSTs one call.

## The numbers

```
round 667 before (and with the marker switched off)
  http2 responder, bad frame      innocent [13, 13, 13]
  channel responder, 20 headers   innocent [3, 3, 3]
  http2 client connection, RST    innocent [14, 14, 14]
controls (offending stream clean)  innocent [ok, ok, ok]
round 667 after                   innocent [ok, ok, ok] in all three
```

## Measures

The outcome of the three innocent calls, at the caller.

## Control

The same run with the offending stream sent clean.

## What it establishes, and what it does not

Establishes whether an error about one stream reaches the calls beside it. Does
NOT cover `rpc_dart_http`'s caller, whose per-request errors also reach the
broadcast un-marked (`B-246`).
