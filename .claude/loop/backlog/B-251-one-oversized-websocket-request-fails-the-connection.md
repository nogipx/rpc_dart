---
status: decided by owner (round 676)
round: — (not re-measured)
commit: 81530a7b
paths: [packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
probe: .dart_tool/probe/parity_matrix.dart (5.request-over-limit, 5.connection-usable-after-over)
reason: owner decision — the close is deliberate; whether the caller's status should say so is a design call
---

# B-251 — one oversized websocket request fails the whole connection as UNKNOWN

Measured outside a round, by the transport parity matrix (`probe:` above), at the `commit:` sha.

Client sends a 66560-byte request against a server limit of 65536:

```
            the call                                   next call, same connection
websocket   2 "WebSocket closed by peer with code      9 "Transport is closed"
            4400: Incoming frame buffer overflow"
http1       8 "HTTP 413 ..."                           OK
http2       8 "gRPC frame payload is too large"        OK
```

The server closes on purpose: `closeOnOversizedFrame: !isClient`
(`channel_transport.dart:226`). The reason is at
`frame_multiplexed_channel.dart:56`: dart:io has already buffered the whole
message, so closing is the only lever left. The client direction refuses only
the call with 8.

## Why it matters

The close is defensible. What the caller sees is not: UNKNOWN for a size
violation, while http1 and http2 say RESOURCE_EXHAUSTED for the same thing. Every
other call on the connection dies too, and nothing on the caller side tells it
the cause was a size. 4400 is used for every protocol error, so the code alone
cannot carry it.

## Options

- A dedicated close code for "message too large", mapped to RESOURCE_EXHAUSTED
  on the caller.
- Leave it and document the difference in the websocket README.

## Owner decision

2026-10-07, round 676's batch: **a dedicated close code for "message too
large", mapped to RESOURCE_EXHAUSTED on the caller**. The connection still
closes.
