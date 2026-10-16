---
round: 877
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-325 — reused
commit: yes
release: changelog
severity: S2 — "a status or error type a caller branches on"
---

# Round 877 — a single request runs only once it ends

## Target

B-292, decided by the owner on 2026-10-16 (option A). Unary and server
stream start their handler only after the request stream ends, as grpc-go
does: `serverStream.RecvMsg` on a non-client-streaming method makes a
second `recv` that must return `io.EOF` before the user's method gets the
request. A tail or a second message is then refused before the handler
runs.

## Hypothesis

Both responders dispatch the handler on the first decoded message. Holding
that message until the half-close, and refusing anything else before it,
moves every malformed row to INTERNAL with the handler not run, and leaves
every valid call as it was.

## Before

```
P-325 (core, channel), handler side effects:
  one chunk     items  whole+second 13 [ran x]  cut 0 [ran x]  undecodable 0 [ran x]
  three chunks  echo   every row 13 [ran x]
                items  whole+second 13 [ran x]; over-limit, cut, undecodable, compressed 0 [ran x]
P-323 (http2), END_STREAM on empty data:
  echo   whole + 3 bytes 0 [echo(x)]; whole + prefix promising 9 0 [echo(x)]
  items  whole + 3 bytes 13 [items(x)]
P-323, END_STREAM on trailers: echo 13 [echo(x)]; items prefix 9: 0 [items(x)]
P-316 (http): items trailing junk byte 0 [items(x)]; two messages 13 [items(x)]
```

## Mechanism

`ServerStreamResponder` ran `handler(request)` from the request listener's
first `onData`; the end of the request stream (`onDone`) came after the
handler had answered and the OK trailer was out. `UnaryResponder.
handleMessage` ran the handler on the first whole message; a second message
only set `tooManyRequests`, which turned the answer into INTERNAL after the
handler had run.

The fix:

- Server stream: `onData` holds the request in `_pendingRequest`. A second
  message is refused with `tooManyMessages`. `onDone` runs the handler
  (`_serve`), and `onError` (a cut, a cancel) answers without running it.
- Unary: a whole request whose message does not carry the end of the stream
  is held (`hasPendingRequest`). `handleMessage` returns "incomplete", so
  the pipeline routes later frames back to it. More data is refused; the
  half-close calls the new `finishRequest`, which serves the held request,
  or answers an incomplete one as before. The pipeline's two
  `answerIncompleteRequest` sites now call `finishRequest`.
- `UnaryResponder` built directly (it listens to the transport itself)
  dropped a half-close that arrived on a metadata frame, because the
  metadata branch returned before the end-of-stream check.
  `an_extra_request_fails_only_its_own_stream_test` timed out until that
  branch let the half-close through.
- `requestEndedMidMessage()` in `protocol.dart` names round 876's status
  once, for `_endRequests`.

## After

```
P-325 (core): echo and items, every malformed row 13 (8 over-limit), handler []
  in both one chunk and three chunks; collect and chat unchanged
P-323 (http2): echo and items, every malformed row 13, handler [], on all three
  endings; whole: 0 [echo(x)] / [items(x)]
P-316 (http): items trailing junk byte 13 [], two messages 13 []; valid 0
```

## Canary

Unary hold switched off in place (`1 < 0 && !message.isEndOfStream`), and
the server stream made to serve on the first `onData` again: 10 rows red.
`Expected: '13' Actual: '0'` on both shapes, over channel and http2, and
`Expected: empty Actual: ['echo']` / `['items']`. Restored: green. The
metadata half-close line switched off (`1 > 0 ||`):
`an_extra_request_fails_only_its_own_stream_test`
`TimeoutException after 0:00:05`.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2249 ~1, http2 +364, http +261, websocket +331, isolate +102,
conformance +620 ~152); `format:check` SUCCESS after `dart format` on two
files, analyze re-run after it; `license:check` compliant.

The first gate run was red on tests that sent a unary request with no
half-close and expected it to be served, or waited for the handler before
sending more. These are the behaviour this round changes, and they were
updated:

- `client_stream_sink_is_bounded_test`: three rows now half-close.
- `the_connection_total_is_bounded_test`: no longer waits for a handler
  that now never starts.
- `server_stream_test`: waits 50 ms for the half-close that `send()` does
  not await.

That run also had one red row each in http2 and conformance, whose text was
lost to the truncated output. Neither came back in two later runs (the gate
and a scoped run of both suites). It is not known whether they were B-297's
flake or something this change does under load.

## Siblings

- unary: `a_single_request_runs_only_once_it_ends_test` (echo rows), the http2 rows, P-325, P-323, P-316
- server: the same test (items rows), the http2 rows, P-325, P-323, P-316
- client: P-325, P-323 and P-316 collect rows unchanged; client stream already started on its request stream and the decision does not touch it
- bidirectional: P-325, P-323 and P-316 chat rows unchanged, likewise
- caller: read — the callers already half-close: the unary one sends its request with `endStream: true`, the server-stream one calls `finishSending` after `send`
- responder: fixed here
- channel: `a_single_request_runs_only_once_it_ends_test`, P-325
- http: P-316
- http2: `a_request_cut_mid_message_is_refused_test` echo and items rows, P-323
- websocket: conformance +620 over every transport, websocket +331 — valid calls are still served; no transport-side request parser of its own
- isolate: conformance and isolate +102 — whole messages cross the port, so only the valid-call half applies
- wasm: read — the same core responders over a byte channel; its tests are outside the gate

## Not fixed

A peer that sends one whole unary request and never half-closes now holds
the decoded request and its stream until a deadline or disconnect.
`halfOpenStreamTimeout` is cancelled at dispatch, so it does not cover
this. This is the residual `_armHalfOpenReclaim`'s doc already names for
the streaming shapes ("one request frame gets the handler dispatched and
then waiting forever"). It is bounded per stream by `maxMessageLengthBytes`
and in count by the concurrent-stream limit.

The zero-copy unary path (`handleDirectMessage`) is unchanged: a direct
object is whole by construction and arrives with the end of the stream.

## Links

Lead `../backlog/B-292-a-server-stream-request-with-trailing-bytes-is-answered-ok.md`.
Round `876-a-request-cut-mid-message-is-answered-internal.md`. Lens
`../lenses/RPC-25-the-same-abstraction-four-times.md`.
