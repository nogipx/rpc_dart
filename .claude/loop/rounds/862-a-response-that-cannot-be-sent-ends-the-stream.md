---
round: 862
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-329 — new
commit: yes
severity: S1 — "data lost, corrupted, duplicated or delivered to the wrong call"
release: changelog
---

# Round 862 — a response that cannot be sent ends the stream

## Target

Round 861's mirror: a failure only the RESPONDER sees, a response its
codec cannot serialize. Round 641 covered the caller's request side; the
journal has nothing on the response side. RPC-25 across the four shapes.

## Hypothesis

A response the responder cannot put on the wire ends the call there with
an error, on every shape. Fails if the caller reads later responses as if
none were missing.

## Before

```
P-329 bad, handler's second value unserializable:
unary   ERROR 13 Internal server error
client  ERROR 13 Internal server error
server  ok0, ok2, ok3, ok4      no error
bidi    ok0, ok2, ok3, ok4      no error
control: unary and client OK; server and bidi ok0, ok1, ok2, ok3
http2 copy, server and bidi: ok0, ok2, ok3
```

The second response is gone and the stream reads as complete up to where
the consumer stopped. The error was recorded (`_responseSendFailure`) and
answered only by `finishSending`, at the end of the handler's stream,
which an endless stream never reaches.

## Mechanism

`_transmitResponse` catches the codec's throw, records it and returns; the
send it belonged to resolves normally. The server-stream pump and the
bidi pump (`_pumpBidirectionalResponses`) `await send` and go on to the
next response, and those serialize and go out. A first attempt sent the
error trailer from inside the send sequence: the caller saw the error at
the gap, but the pumps kept the handler producing (41 and 83 items in
0.5 s), since a send on an answered processor returns silently.

## Fix

- `StreamProcessor.isAnswered`: the trailer is out, the response stream is
  closed, or a response failed to go out.
- The server-stream pump and the bidi pump stop at `isAnswered` after each
  send; the `finishSending` that follows answers the recorded failure, as
  before, once.

## After

```
P-329 bad: server and bidi ok0, then ERROR 13; handler 1 more in 0.5 s
           (the step already in flight, as in control)
http2 copy: server and bidi ok0, error 13
control unchanged
```

## Canary

Witness `packages/core/rpc_dart/test/streams/a_response_that_cannot_be_sent_ends_the_stream_test.dart`:

- server pump's check off: "WITNESS server: a response that cannot be
  serialized ends the stream there" failed with `Expected: ['ok0', 'error
  13'] Actual: ['ok0', 'ok2', 'ok3']`;
- bidi pump's check off: the bidi row failed the same way.

GUARD rows (every response serializes; the handler stops) green in every
arm. A third part, skipping sends queued behind a failure inside
`_transmitResponse`, changed no witness when switched off and was removed.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2229 ~1, http2 +358, http +261, websocket +331, isolate +102,
conformance +512 ~150); `format:check` SUCCESS; `license:check` compliant.

## Siblings

- server: fixed here
- bidirectional: fixed here
- unary: clean — P-329, ERROR 13 before the fix
- client: clean — P-329, ERROR 13 before the fix
- responder: fixed here
- caller: read — round 641's record: a request the caller cannot serialize fails the call on every shape; not re-measured here
- channel: fixed here — P-329 runs on `RpcChannelTransport.pair`
- websocket: fixed here — `RpcChannelTransport`, P-329's path
- isolate: fixed here — `RpcChannelTransport`, P-329's path
- wasm: fixed here — `RpcChannelTransport`, P-329's path
- http2: fixed here — P-329's http2 copy, ok0, ok2, ok3 before and ok0, error 13 after
- http: fixed here — the responders are core's; not measured on http

## Not fixed

- `BidirectionalStreamResponder.responseSink` (a `SinkPump`) logs a failed
  send and keeps pumping; the endpoint does not use it, direct users of the
  responder do. Not measured.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Bench
`../probes/P-329-a-response-the-responder-cannot-serialize.md`. Rounds
`861-a-bidi-call-that-fails-locally-tells-the-server.md`,
`641-a-request-that-cannot-be-sent.md`.
