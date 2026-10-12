---
round: 855
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: P-322 — new
commit: yes
severity: S1 — "data lost, corrupted, duplicated or delivered to the wrong call"
release: changelog
---

# Round 855 — a cut http2 stream is an error on every ending

## Target

The round-853 sweep's second candidate: the http2 caller checks for a
partial frame only when a trailer HEADERS frame ends the stream (round
846), not on the DATA END_STREAM path with a status already known, nor in
`onDone`. Its first candidate was the side sibling: the http2 responder
never checks at all, because it hands whole frames up and the core check
(round 554, `holdsPartialFrame`) never sees the tail. The channel transport
already answers the caller shape (P-317 "status on DATA end": ERROR 13).
RPC-25: one rule, written on one ending of one side.

## Hypothesis

On http2, a response or request that ends inside a gRPC frame ends with an
error however the stream ends. Fails if a cut stream ends OK.

## Before

```
P-322 (caller, server stream, two whole frames then `cut` bytes):
  status in HEADERS, END on the DATA        cut 0  2 items CLEAN END   (control)
                                            cut 2  2 items CLEAN END
                                            cut 7  2 items CLEAN END
  status in HEADERS, END on an empty DATA   cut 2  2 items CLEAN END
                                            cut 7  2 items CLEAN END

P-323 (responder), END on the DATA:
  echo     whole + 3 bytes   grpc=0  handler [echo(x)]
  items    whole + 3 bytes   grpc=0  handler [items(x)]
  collect  cut at 7          grpc=0  handler [collect([])]
  chat     cut at 7          grpc=0  handler [chat([])]
  END on an empty DATA or on trailers: the same, every cut row
  whole (control): grpc=0, the handler got x, every shape and ending
```

A client stream cut inside its only message ran the handler on an empty
request stream and answered OK.

## Mechanism

Both http2 inbounds parse DATA into whole frames with their own per-stream
parser and emit only those. The bytes of a cut frame stay in that parser.
The core processor's end-of-stream check reads its own parser, which only
ever saw whole frames, so it passes. Round 846 checked the transport
parser on the caller's trailer path alone. And an empty END_STREAM DATA
frame never arrives as a message from package:http2; the stream just
finishes, through `onDone`.

## Fix

- Caller (`rpc_http2_caller_transport_inbound.dart`): the DATA path, with a
  status known and END_STREAM on a chunk that leaves a partial frame,
  emits the whole frames without the end flag, then INTERNAL; `onDone` with
  a status known does the same. Both share `_failEndedMidMessage` with the
  trailer path.
- Responder (`rpc_http2_responder_transport_inbound.dart`):
  `_refuseIfEndedMidMessage` on the DATA END_STREAM path, on trailers, and
  in `onDone`, answering through `_answerFramingViolation` (INTERNAL, the
  handler's request stream torn down, a strike towards the protocol-error
  limit). The parser goes with the refusal so a later end does not refuse
  twice.

## After

```
P-322: every cut row ERROR 13 "Response stream ended mid-message", both endings;
       cut 0 CLEAN END
P-323: every cut row grpc=13 "Request stream ended mid-message" on all four
       shapes and all three endings, except the B-292 rows below; whole grpc=0
```

## Canary

- Caller DATA path off (`1 < 0 &&`):
  `rpc_dart_http2/test/a_response_cut_mid_message_is_an_error_test.dart`
  "WITNESS a status in the headers, then DATA ending mid-frame" failed with
  `Expected: <Instance of 'RpcStatusException'> with statusCode: <13>
  Actual: <null>`.
- Caller `onDone` off: "WITNESS ... an empty END_STREAM DATA after a cut
  frame" failed the same way.
- Responder `_refuseIfEndedMidMessage` off:
  `rpc_dart_http2/test/a_request_cut_mid_message_is_refused_test.dart`, all
  14 witnesses failed (`Expected: '13' Actual: '0'` for collect and chat,
  `Actual: '3'` for echo and items); every GUARD green.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2220 ~1, http2 +350, http +261, websocket +331, isolate +102,
conformance +512 ~150); `format:check` SUCCESS; `license:check` compliant.

## Siblings

- http2: fixed here
- channel: clean — P-317 row "one message + 3 bytes, status on DATA end": stream and bidi ERROR 13; the core processor parses whole chunks itself
- websocket: clean — its caller is an `RpcChannelTransport`, the path P-317 measures (the same reasoning as rounds 846 and 853)
- isolate: clean — `RpcChannelTransport`, the path P-317 measures
- wasm: clean — `RpcChannelTransport`, the path P-317 measures
- http: clean — P-316 (round 847): collect and chat refuse a trailing byte with grpc=3, echo with 13; fuzz_http_client (round 846) refuses a cut response
- caller: fixed here
- responder: fixed here
- unary: fixed here — P-323 echo, END on the DATA
- server: fixed here — P-323 items
- client: fixed here — P-323 collect
- bidirectional: fixed here — P-323 chat

## Not fixed

- B-292, widened: a unary or server-stream request whose whole message and
  trailing bytes arrive in DIFFERENT chunks is answered OK on http2, because
  both responders dispatch on the first whole message (expected on the
  other transports too; not measured). P-323 rows `echo` / `items`, whole +
  3 bytes or prefix, ended on an empty DATA or on trailers: grpc=0.
- B-294: the refused client-stream and bidi handlers still run to
  completion on whatever came before the cut.
- The responder logs each refusal at error level (`Error decoding incoming
  gRPC data`), as every framing refusal on this path does.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Benches
`../probes/P-322-an-http2-response-cut-after-its-status.md`,
`../probes/P-323-an-http2-request-cut-mid-message-per-shape-and-ending.md`,
`../probes/P-317-what-a-channel-caller-accepts-from-a-hostile-server.md`.
Leads `../backlog/B-292-a-server-stream-request-with-trailing-bytes-is-answered-ok.md`,
`../backlog/B-294-a-refused-upload-ends-its-handler-input-cleanly.md`.
Rounds `846-a-response-cut-mid-message-is-an-error.md`,
`847-a-unary-request-with-trailing-bytes-is-refused.md`.
