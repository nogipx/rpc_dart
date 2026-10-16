---
round: 878
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-317 — reused
commit: yes
release: changelog
severity: S2 — "a status or error type a caller branches on"
---

# Round 878 — the END_STREAM status ends every shape

## Target

B-296. The owner first decided option 1 (the first status wins). Option 1,
implemented, broke 4 rows of the http2
`a_response_cut_mid_message_is_an_error_test` (rounds 853/858). In those
rows a status arrives in headers without END_STREAM, then DATA, and the
test expects the messages delivered: `Expected: ['item', 'item'] Actual:
[]`. grpc-go's `operateHeaders`, read in its source, parses such a status
and never uses it; the status is built only on the END_STREAM path. Both
facts went back to the owner, who changed the decision to option 2: the
status on the END_STREAM frame wins on every shape. Option 1 was reverted
uncommitted.

## Hypothesis

Every caller-side site that reads a status reads it from any metadata
frame. Gating each on `isEndOfStream` makes all four shapes take the same
status.

## Before

```
P-317 (channel)                       unary   stream    client  bidi
OK without end, then 13 with end      OK a    ERROR 13  OK a    ERROR 13
P-326 (http2)
two trailers, OK then 13              OK a    ERROR 13  OK a    ERROR 13
```

## Mechanism

Eight readers of a caller-side status, counted by grep for
`RpcCallerTrailer.statusOf` under `lib/src/rpc/streams` and
`caller_pipeline.dart`:

- the unary caller's listener and the client-stream caller's listener
  completed on any status;
- `_grpcStatusErrorTransformer` (server stream and bidi) and the server
  caller's `call()` and the bidi caller's `payloadResponses` failed on any
  non-OK status;
- `caller_pipeline.dart` set `serverEnded` on any status, and the
  zero-copy `_executeUnaryCall` completed on any status.

All of them now read only a frame carrying END_STREAM. The ninth, the
base processor's synthesized CANCELLED header, is local and needs nothing.

Gating unary exposed a split of its own: a status without END_STREAM, then
a DATA frame cut mid-message carrying END_STREAM. Unary ended in `onDone`
with the retryable 14 "closed before the peer sent status", while the
other three said 13 "ended mid-message". `onDone` now answers
`responseEndedMidMessage()` when the parser holds part of a frame.

## After

```
P-317 (channel): every row equal across the four shapes
  OK without end, then 13 with end   ERROR 13 x4
  13 without end, then OK with end   OK a x4
  status first, then a cut DATA end  ERROR 13 mid-message x4 (unary was 14)
P-326 (http2): two trailers, OK then 13   ERROR 13 x4
```

## Canary

All gates switched off in place (`1 > 0 ||` / `1 < 0 &&`): 6 rows red,
`Expected: 'ERROR 13' Actual: 'OK a'` (unary, client) and `Expected: 'OK a'
Actual: 'ERROR 13'` (all four). `onDone` alone off: the unary cut row,
`Expected: 'ERROR 13' Actual: 'ERROR 14'`. Restored: +16 green.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2265 ~1, http2 +364, http +261, websocket +331, isolate +102,
conformance +620 ~152); `format:check` SUCCESS; `license:check` compliant.

The first gate run was red on two tests:

- rpc_dart: round 875's `a_unary_call_survives_a_late_or_failed_frame_test`
  GUARD timed out. It fed a status without END_STREAM to complete the call,
  which no longer completes it, so it now sends the status with the flag.
- http2: one test, whose text was lost to the truncated output. It was
  green in a scoped run and in the full gate after; this is the second
  such unidentified single http2 red under gate load in three rounds.

## Siblings

- unary: `the_end_of_stream_status_ends_every_shape_test`, P-317, P-326
- client: the same test, P-317, P-326
- server: the same test, P-317, P-326
- bidirectional: the same test, P-317, P-326
- caller: fixed here
- responder: read — the decision is about what a caller accepts; responders send their status with END_STREAM (`forTrailer(...)`, `endStream: true`)
- channel: the test and P-317
- http: read — the http caller transport emits its trailer as one message with `isEndOfStream: true` (`rpc_http_caller_transport.dart`, the trailer `_emit`), so the gate changes nothing there; http +261 green
- http2: P-326, and `a_response_cut_mid_message_is_an_error_test` green
- websocket: read — its caller is `RpcChannelTransport`, the same frames as P-317's channel; websocket +331 green
- isolate: read — the same channel transport; isolate +102 green
- wasm: read — the same channel transport over a byte channel

## Not fixed

A peer that sends its status without ever setting END_STREAM now leaves a
unary or client-stream call to its deadline, as streaming calls already
were. This is the cost the owner accepted.

The zero-copy `_executeUnaryCall` gate has no witness: zero-copy runs only
in process, where the responder always sends END_STREAM.

## Links

Lead `../backlog/B-296-a-status-without-end-of-stream-ends-unary-and-not-a-stream.md`.
Rounds `853-a-unary-response-with-trailing-bytes-is-an-error.md`,
`875-the-unary-callers-send-failure-guard-gets-a-witness.md`. Lens
`../lenses/RPC-25-the-same-abstraction-four-times.md`.
