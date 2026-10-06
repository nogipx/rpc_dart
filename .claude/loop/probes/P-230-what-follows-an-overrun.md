---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/b186_overrun_order.dart
round: 666
commit: 5d70d210
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
status: valid
---

# P-230 — what follows an overrun

## Why it exists

B-186: the un-consumed window refuses a call from inside `_emit`, before the
message that overran it is delivered -- so that message goes out behind the
refusal. Both http2 transports meter the same way.

## The harness

Two files. `b186_overrun_order.dart`: a raw peer answers 200 gRPC with 8 x 4 KiB
messages, the caller's window is 16 KiB, and the per-stream consumer is paused
from before the request until 500 ms in. `b186_responder_overrun_order.dart`:
the mirror, a `RpcHttp2ResponderTransport` with a 16 KiB window and a paused
per-stream view, fed 8 x 4 KiB by a caller. Each prints the consumer's events in
order and counts payloads after the refusal.

## The numbers

```
round 666 before
  caller     [headers, data, data, data, ERROR, data, done]   data after 1
  responder  [data, data, data, CANCEL, data, CANCEL, ...]    data after 1
round 666 after
  caller     [headers, data, data, data, ERROR, done]         data after 0
  responder  [data, data, data, CANCEL, CANCEL, ...]          data after 0
```

## Measures

The per-stream consumer's event order, at the transport's own stream.

## Control

The pause is the variable that makes the overrun happen: paused 100 ms in,
after all 32 KiB had arrived, the caller arm shows eight `data` and no refusal.

## What it establishes, and what it does not

Establishes whether anything is delivered after the window refuses a call. Does
NOT measure the endpoint pipeline's reaction to such a payload.
