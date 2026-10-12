---
round: 857
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: P-325 — new
commit: yes
severity: S2 — "a status or error type a caller branches on"
release: changelog
---

# Round 857 — a cut http2 request is refused with core's status

## Target

Round 856's question on core: does a core refusal mid-upload reach the
handler as an error? P-325 says yes on every refusal kind, and in passing
showed the status core gives a request that ends mid-frame: 3. Round 855
made http2 answer the same request 13. Invariant I-7, "one failure, one
status", holds across the transport group; this round's own fix of 855
broke it.

## Hypothesis

A request that ends inside a gRPC frame gets the same status on http2 as
on the transports core parses for. Fails if they differ.

## Before

```
P-325 (core, channel), cut-only, one chunk and three:
  echo 3   items 3   collect 3   chat 3
  whole + cut (one chunk): collect 3, chat 3, echo 13 (round 847), items 0 (B-292)
  every handler of a refused upload: ERROR, never DONE   (control: whole, DONE [x, x])

P-323 (http2, after rounds 855-856), cut at 7 on every ending:
  echo 13   items 13   collect 13   chat 13
P-316 (http, round 847): collect and chat 3 for a trailing byte, echo 13
```

## Mechanism

Core answers from `_endRequests`: a parser holding a partial frame at the
end of the request stream raises INVALID_ARGUMENT, "Request stream closed
mid-message: the last gRPC frame is incomplete" (rounds 553-554). Round 855
put the http2 refusal in the transport, because core never sees the tail
there, and wrote its own status and text.

## Fix

`_refuseIfEndedMidMessage` (http2 responder) answers with core's status
and text: INVALID_ARGUMENT, "Request stream closed mid-message: the last
gRPC frame is incomplete".

## After

```
P-323: every cut row grpc=3 with core's text, on all four shapes and all
three endings; whole rows grpc=0
```

## Canary

`rpc_dart_http2/test/a_request_cut_mid_message_is_refused_test.dart` with
the status put back to INTERNAL in place: all 14 refusal witnesses failed
with `Expected: '3' Actual: '13'`; every GUARD green.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2220 ~1, http2 +358, http +261, websocket +331, isolate +102,
conformance +512 ~150); `format:check` SUCCESS; `license:check` compliant.

## Siblings

- http2: fixed here
- channel: clean — P-325, cut-only 3 on all four shapes (the reference)
- websocket: clean — `RpcChannelTransport`, the path P-325 measures
- isolate: clean — `RpcChannelTransport`, the path P-325 measures
- wasm: clean — `RpcChannelTransport`, the path P-325 measures
- http: clean — P-316 (round 847), collect and chat 3 for a trailing byte
- responder: fixed here
- caller: clean — the response side answers 13 "Response stream ended mid-message" on core (P-317) and http2 (P-322) alike
- unary: fixed here
- server: fixed here
- client: fixed here
- bidirectional: fixed here

## Not fixed

- B-295 (owner): grpc-go answers this request INTERNAL, not
  INVALID_ARGUMENT; and a unary whole message plus tail in one chunk is
  13 on core and http, 3 on http2.
- No conformance row holds I-7 for this request; P-323, P-325 and P-316
  are three separate probes.
- B-292's text corrected: on core the unary responder answers a later tail
  13 (after running the handler); only the server stream answers 0.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Benches
`../probes/P-325-what-core-answers-a-request-refused-mid-stream.md`,
`../probes/P-323-an-http2-request-cut-mid-message-per-shape-and-ending.md`,
`../probes/P-316-a-malformed-grpc-body-on-each-shape.md`. Leads
`../backlog/B-295-which-status-a-request-cut-mid-message-gets.md`,
`../backlog/B-292-a-server-stream-request-with-trailing-bytes-is-answered-ok.md`.
Rounds `855-a-cut-http2-stream-is-an-error-on-every-ending.md`,
`554-one-rule-where-the-parser-is.md`.
