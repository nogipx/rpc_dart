---
round: 772
commit: ca0e7cfe
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart, packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
scope: maxMessageLengthBytes on channels that carry whole messages (isolate, wasm bridge); network transports are checked
---

# C-67 — the message limit is the frame layer's

`RpcSecurityPolicy.maxMessageLengthBytes` is enforced where bytes are
parsed into messages: `RpcFrameMultiplexedChannel`, the gRPC parser, the
HTTP body readers, the websocket frame guard. `RpcChannelTransport._onMessage`
checks inbound metadata only, on the stated assumption that "the frame
layer bounds payload length". A channel that hands over whole messages —
the isolate channel, the wasm bridge — has no frame layer, so the limit
does not apply there: round 772 sent 70000 bytes both ways through an
isolate under a 64 KiB limit.

Not fixed, and why: the peer on such a channel is the same process (the
app's own worker or guest), which already allocated the message; the limit
exists to stop an untrusted peer from making this process allocate. The
README's "applied to both sides" holds for flow control and metadata.

Re-open if a whole-message channel ever carries an untrusted peer.

## Control

The same 70000-byte rows on websocket, http2 and http: refused with
status 8 (P-272).
