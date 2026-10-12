---
round: 846
verdict: FIXED
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-25
bench: P-315 — new
commit: yes
severity: S1 — "data lost, corrupted, duplicated or delivered to the wrong call"
release: changelog
---

# Round 846 — a response cut mid-message is an error

## Target

Round 844 found that P-225 has no harness for the http caller either. A new
one, `rpc_dart_http/.dart_tool/probe/fuzz_http_client.dart` (a hostile raw
HTTP/1.1 server answering with mutations of a real `RpcHttpServer` response,
calls with a 1 s deadline), ran 300 sessions: no hang, nothing in the zone.
Its oracle was then sharpened to print every accepted answer to a mutation
that should fail, which found two: a `content-length` that cuts the last
frame (27 of 30 bytes) and a first frame prefix that promises more than the
body holds, both under `grpc-status: 0`, both delivered as a clean end.

The request side has answered this shape since rounds 554 and 629 with
`RpcMessageParser.holdsPartialFrame`; the response side never checked it.
`holdsPartialFrame` has five uses in `lib/`, all on the responder. RPC-25:
one rule, written on one of two siblings.

## Hypothesis

A response stream that ends inside a gRPC frame ends with an error. Fails if
the consumer gets a clean end and fewer items than were sent.

## Before

```
P-315 (channel)   cut    items   error
                  0      2       none        (control)
                  2      2       none
                  5      2       none
                  7      2       none

fuzz_http_client, 400 sessions, server stream under grpc-status 0:
  content-length 27 of 30          ok, 2 items  (x7)
  first prefix 90, body 30         ok, 0 items  (x5)
  first prefix 16777216, body 30   ok, 0 items  (x2)
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/r846_truncated_response.dart`.

## Mechanism

The caller processor parses response payloads into frames and keeps a
partial one for the next chunk. On the end of stream it passed the OK
trailer on and closed, so the bytes in the parser were dropped. The http2
caller parses frames itself and hands up whole ones only, so its partial
frame stayed in its own per-stream parser, out of the core's sight.

## Fix

- `base_processor_caller.dart`: on an end of stream, `_failIfEndedMidMessage`
  checks the parser and ends the call with INTERNAL ("Response stream ended
  mid-message: the last gRPC frame is incomplete") instead of the trailer.
  Every transport that parses responses in core is covered.
- `rpc_http2_caller_transport_inbound.dart`: the final trailer is replaced by
  the same INTERNAL when the stream's parser holds a partial frame.

## After

```
P-315             cut    items   error
                  0      2       none
                  2      2       RpcStatusException(13) ... the last gRPC frame is incomplete
                  5      2       the same
                  7      2       the same

fuzz_http_client, 400 sessions: the content-length 27 and lying-prefix
sessions refused; still accepted only content-length 0 (an empty body,
nothing cut), application/grpc+json, and a well-formed chunked body.
```

## Canary

Witnesses `packages/core/rpc_dart/test/streams/a_response_cut_mid_message_is_an_error_test.dart`
(cuts at 2, 5, 7; GUARD a stream ending between frames) and
`packages/transport/rpc_dart_http2/test/a_response_cut_mid_message_is_an_error_test.dart`
(a raw h2 peer; GUARD three whole frames).

- Core half off: all three core witnesses failed with `Expected: <Instance of
  'RpcStatusException'> with statusCode: <13> Actual: <null>`; GUARD green.
- http2 half off: the http2 witness failed the same way; its GUARD green.

The core witness also passes on node.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2210 ~1, http2 +318, http +259, websocket +331, isolate +102,
conformance +512 ~150); `format:check` SUCCESS; `license:check` compliant.

## Siblings

- channel: fixed here (the core caller processor; P-315 and the core witness run on `RpcChannelTransport`)
- websocket: fixed here — its caller is an `RpcChannelTransport`, the core witness's path
- isolate: fixed here — `RpcChannelTransport`, as websocket
- wasm: fixed here — `RpcChannelTransport`, as websocket
- http: fixed here — through the core half; `fuzz_http_client` refuses the cut sessions it accepted before
- http2: fixed here (its own half; the http2 witness)
- caller: fixed here
- responder: n/a — the request side has refused a stream that ends mid-message since rounds 554 and 629 (`holdsPartialFrame`)

## Not fixed

- The unary caller already refused these (one message expected, none
  whole), so only streaming responses lost data.
- `fuzz_http_client.dart` joins P-225's harness list.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Bench
`../probes/P-315-a-response-cut-mid-message.md`, harness
`../probes/P-225-what-a-fuzzer-finds-in-the-decoders-and-the-servers.md`.
Leads `../backlog/B-231-a-bare-prefix-reads-as-a-clean-end.md` (the request
side), round `554-one-rule-where-the-parser-is.md`.
