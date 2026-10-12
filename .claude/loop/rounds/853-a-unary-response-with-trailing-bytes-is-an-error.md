---
round: 853
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-320 — new
commit: yes
severity: S2 — "a status or error type a caller branches on"
release: changelog
---

# Round 853 — a unary response with trailing bytes is an error

## Target

A code-reading sweep for caller/responder asymmetries named the unary
caller: it never asks its parser `holdsPartialFrame`. Round 846 fixed that
check for the streaming shapes in `base_processor_caller.dart` and wrote
"the unary caller already refused these", which held only for a cut with no
whole message before it. Round 847 fixed the same shape on the unary
responder. RPC-25, ranked first: one rule, three of four copies.

P-317 already had the row, and C-86 (round 851) recorded the four shapes as
agreeing without noticing it disagreed.

## Hypothesis

A unary response of one whole message and the start of a second, under
grpc-status 0, ends INTERNAL like the other three shapes. Fails if the call
returns the first message OK.

## Before

```
P-317, "one message + 3 bytes, OK" (channel transport):
  unary  : OK value=a
  stream : ERROR 13 Response stream ended mid-message
  client : ERROR 13 Response stream ended mid-message
  bidi   : ERROR 13 Response stream ended mid-message

P-320 (http, a real RpcHttpServer response with bytes appended):
  none        OK value=x   (control)
  3 bytes     OK value=x
  prefix + 1  OK value=x
```

## Mechanism

The unary caller parses each DATA chunk, holds the one whole message, and on
an OK status completes with it. The bytes left in the parser after that
message were never looked at, so a second message cut short was dropped and
the call read as a clean answer. Two whole messages already failed
("More than one response").

## Fix

- `unary/caller.dart`: on an OK status, a parser holding a partial frame
  ends the call with INTERNAL instead of the held response.
- `core/protocol.dart`: `responseEndedMidMessage()` builds that error;
  `base_processor_caller.dart` uses it too, so the four shapes share one
  message.

## After

```
P-317, "one message + 3 bytes, OK": all four ERROR 13 Response stream ended mid-message
                                     every other row unchanged
P-320: none OK value=x; 3 bytes and prefix + 1 ERROR 13 Response stream ended mid-message
```

## Canary

Fix off in place (`1 < 0 &&`):

- `packages/core/rpc_dart/test/streams/a_response_cut_mid_message_is_an_error_test.dart`,
  "WITNESS a unary response with a cut second frame ends with INTERNAL"
  failed with `Expected: <Instance of 'RpcStatusException'> with statusCode:
  <13> Actual: 'item'`; its GUARD and the streaming rows green.
- `packages/transport/rpc_dart_http/test/a_unary_response_with_trailing_bytes_is_an_error_test.dart`
  (P-320 promoted) failed the same way; GUARD green.
- The http2 unary witness added to
  `packages/transport/rpc_dart_http2/test/a_response_cut_mid_message_is_an_error_test.dart`
  stayed green with the fix off: the http2 caller's own check from round 846
  already refuses it.

Fix on: all green.

## Gate

`melos run analyze` SUCCESS; `melos run format:check` SUCCESS;
`license:check` compliant. `melos run test:unit --no-select`: the first run
failed one isolate test (`startup_failure_releases_the_isolate_test.dart`,
"still running"), which passed alone and in a second full run (rpc_dart
+2217 ~1, http +261, http2 +320, websocket +331, isolate +102, conformance
+512 ~150). Filed as B-293.

## Siblings

- unary: fixed here
- client: clean — P-317 row ERROR 13 (base processor, round 846)
- server: clean — P-317 row ERROR 13
- bidirectional: clean — P-317 row ERROR 13
- caller: fixed here
- responder: clean — `a_unary_request_with_trailing_bytes_is_refused_test.dart` (round 847) green in this gate; the server stream is B-292
- channel: fixed here — P-317 runs on `RpcChannelTransport`
- websocket: fixed here — its caller is an `RpcChannelTransport`, P-317's path
- isolate: fixed here — `RpcChannelTransport`, as websocket
- wasm: fixed here — `RpcChannelTransport`, as websocket
- http: fixed here — through the core unary caller; P-320 and its witness
- http2: clean — `rpc_dart_http2/test/a_response_cut_mid_message_is_an_error_test.dart`, the unary witness, green with the core fix off: the caller transport's per-stream parser check (round 846) refuses it

## Not fixed

- B-293: the isolate startup test that failed once under the full gate.
- The sweep's other candidates (http2 DATA END_STREAM and `onDone` paths,
  the http caller not requiring a grpc-status, bidi buffering before
  subscribe) are unmeasured.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Benches
`../probes/P-317-what-a-channel-caller-accepts-from-a-hostile-server.md` (reused),
`../probes/P-320-a-unary-http-response-with-bytes-after-its-frame.md`.
Negative corrected `../checked/C-86-the-four-caller-shapes-agree-on-a-hostile-server.md`.
Lead `../backlog/B-293-a-failed-isolate-startup-reads-as-still-running-under-the-gate.md`.
Rounds `846-a-response-cut-mid-message-is-an-error.md`,
`847-a-unary-request-with-trailing-bytes-is-refused.md`.
