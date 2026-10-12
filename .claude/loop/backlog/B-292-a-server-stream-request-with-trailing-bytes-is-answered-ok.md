---
status: open
round: 847
commit: 42f23cce
paths: [packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor_responder.dart]
probe: packages/transport/rpc_dart_http/.dart_tool/probe/r847_http_body_oracle.dart — P-316
reason: owner — the fix is to dispatch a server stream only once its request stream has ended, which changes when every server-stream handler starts; grpc-go also starts the handler on the first message
rank: 3
---

# B-292 — a server stream request with trailing bytes is answered ok

A server-stream request body holding one whole message and the start of a
second ends OK, with the handler run (P-316: `items`, trailing junk byte,
`200 grpc=0 handler: [items(x)]`). Two whole messages get INTERNAL ("More
than one request"), but only after the handler has already run. Unary
(fixed in round 847), client-stream and bidi refuse the trailing bytes.

The server stream dispatches its handler on the first request message. The
end of the request stream, where `holdsPartialFrame` is checked, arrives
after the handler has answered and the OK trailer is out, so the refusal has
nowhere to go.

Severity S2 — "a status or error type a caller branches on": a malformed
request is answered OK; the handler received exactly the one message the
peer sent whole.

Round 855 found the same dispatch on unary too, whenever the trailing bytes
arrive in a LATER chunk than the whole message: round 847's check sees the
parser only within the chunk that carries the message. P-323 on http2, a
whole frame, then 3 bytes, then END_STREAM on an empty DATA frame or on
trailers: `echo` and `items` both `grpc=0`, handler run. The core unary
responder dispatches the same way (`handleMessage`, `requestHandled`), so
the split is expected to reach it on every transport; not measured there.

## Fix direction

Wait for the request stream to end before starting the handler, as unary
does; or refuse a partial tail at the point the first message is taken. The
first changes when every server-stream handler starts, which is why it is
the owner's.

## Owner decision

—
