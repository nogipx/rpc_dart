---
round: 847
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-316 — new
commit: yes
severity: S2 — "a status or error type a caller branches on"
release: changelog
---

# Round 847 — a unary request with trailing bytes is refused

## Target

Round 846's oracle turned on the server: what `RpcHttpServer` answers to a
well-formed HTTP request whose gRPC body is malformed, per call shape. The
http fuzzer (round 845) checked only that the server stays live.

## Hypothesis

Every malformed request body is refused on every shape. Fails if one is
answered OK.

## Before

```
P-316, ten bodies x four shapes; the rows that read OK where they should not:
trailing junk byte   echo (unary)    200 grpc=0    handler: [echo(x)]
                     items (server)  200 grpc=0    handler: [items(x)]
                     collect         200 grpc=3    (refused)
                     chat            200 grpc=3    (refused)
two messages         echo            200 grpc=13   handler: []
                     items           200 grpc=13   handler: [items(x)]
```

A unary request of one whole message plus the start of a second ran the
handler and answered OK, where two whole messages are refused INTERNAL.

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/r847_http_body_oracle.dart`.

## Mechanism

The unary responder refused `messages.length > 1` and dispatched on one
whole message, leaving the bytes after it in the parser; it never asked
`holdsPartialFrame`, which the request-stream end checks for the streaming
shapes.

## Fix

A unary chunk that leaves a partial frame behind its one message is refused
like two messages: `tooManyMessages('request')`, INTERNAL, before the
handler runs.

## After

```
trailing junk byte   echo   200 grpc=13 More than one request ...   handler: []
prefix promises less echo   200 grpc=13 More than one request ...   (was 13, "could not be decoded")
```

Every other row unchanged.

## Canary

Witness `packages/core/rpc_dart/test/streams/a_unary_request_with_trailing_bytes_is_refused_test.dart`
(a raw channel, the status read off the frames the responder sends). Check
off: "WITNESS one message and the start of a second is refused" failed with
`Expected: '13' Actual: '0'`; "GUARD one whole message is answered OK" green.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2212 ~1, http +259, http2 +318, websocket +331); `format:check`
SUCCESS; `license:check` compliant.

## Siblings

- unary: fixed here
- client: clean — P-316 `collect`, trailing junk byte: grpc=3, handler not run
- bidirectional: clean — P-316 `chat`, trailing junk byte: grpc=3, handler not run
- server: deferred — B-292 (the handler starts on the first message; the partial tail is checked at the request stream's end, after the OK is out)
- caller: n/a — this is the request side; the response side's partial frame is round 846
- responder: fixed here

## Not fixed

- B-292: the server stream. Fixing it means starting every server-stream
  handler only after its request stream ends, the owner's call.
- A server stream given two whole messages runs its handler before it is
  refused (the same dispatch-on-first-message), noted in B-292.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Bench
`../probes/P-316-a-malformed-grpc-body-on-each-shape.md`. Lead
`../backlog/B-292-a-server-stream-request-with-trailing-bytes-is-answered-ok.md`.
Round `846-a-response-cut-mid-message-is-an-error.md`.
