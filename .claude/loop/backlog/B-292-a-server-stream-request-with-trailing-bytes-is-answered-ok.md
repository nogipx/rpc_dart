---
status: closed (round 877)
release: changelog
round: 847
commit: 42f23cce
paths: [packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor_responder.dart]
probe: packages/transport/rpc_dart_http/.dart_tool/probe/r847_http_body_oracle.dart — P-316
reason: owner — the fix is to dispatch a server stream only once its request stream has ended, which changes when every server-stream handler starts; grpc-go's user method starts only after the request stream ends (owner review 2026-10-16)
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
trailers: `echo` and `items` both `grpc=0`, handler run. Round 857 measured
core (P-325, three chunks): the core unary responder runs the handler on the
first message too, but then answers the tail 13, so on core only the server
stream (`items`) ends `grpc=0`.

## What grpc-go does

Read in grpc-go's source (master, 2026-10-16), not measured against a
grpc-go server. `serverStream.RecvMsg` on a non-client-streaming method
makes a second `recv` that must return `io.EOF`. Another message is
INTERNAL "cardinality violation"; a tail cut mid-message is
`io.ErrUnexpectedEOF`, which `toRPCErr` maps to INTERNAL. The generated
handler calls `RecvMsg` before it calls the user's method. So the user's
method starts only after the request stream ends, and a trailing tail is
refused before it runs. The earlier "grpc-go also starts the handler on the
first message" holds for the generated wrapper only, not for user code.

## Fix direction

Wait for the request stream to end before starting the handler, as unary
does; or refuse a partial tail at the point the first message is taken. The
first changes when every server-stream handler starts, which is why it is
the owner's.

## Owner decision

2026-10-16: option A. Start the handler only after the request stream
ends, as grpc-go does, on unary and server stream. A partial tail or a
second message is refused before the handler runs. The cost was stated to
the owner: a client that holds END_STREAM back delays the start. The
status of the refusal follows B-295 (INTERNAL).
