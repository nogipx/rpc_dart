---
round: 854
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-321 — new
commit: yes
severity: S3 — "diagnostics (log level, log volume, message text)"
release: changelog
---

# Round 854 — a hostile response is logged once

## Target

The same code-reading sweep as round 853 listed nine caller/responder
asymmetries. Three were taken off by current code and measurement first:

- the bidi caller buffering before the application subscribes: measured
  absent through the endpoint (C-88, 0 frames sent before the first listen);
- the http caller not requiring grpc-status: the transport always emits a
  trailer, and P-317's "trailer without status" row is ERROR 13 on all four
  shapes;
- an unsupported grpc-encoding answered INTERNAL on the caller: that is what
  gRPC answers on the receiving client (UNIMPLEMENTED is the server's).

The next was the caller logging decode failures at error level per message.
RPC-25: unary stops at the first undecodable response, the processor the
other three shapes share did not.

## Hypothesis

One response chunk of undecodable messages costs the caller a bounded
number of log records, as on unary. Fails if the count grows with the
number of messages in the chunk.

## Before

```
P-321, one 7 KB chunk of 1000 undecodable 2-byte frames, then OK:
shape    n      consumer saw   log records
server   1      1 error        error 2          (control)
server   1000   1 error        error 1001
bidi     1000   1 error        error 1001
unary    1000   1 error        error 2
```

Each of the 1000 is `Failed to deserialize response` with a stack trace.

## Mechanism

`_processResponseData` decodes every frame the parser returns. A failure
logged an error, added the INTERNAL to the response controller and went on
to the next frame, so a peer chose the record count with the size of its
chunk. The endpoint cancels the call on the first error it receives, but
that is after the whole chunk has been decoded.

Ending the call at the first failure opens a second path: data that
arrives after the controller is closed went to `Cannot add response to
closed controller`, one warning per message. With the first half alone,
`more` (a second chunk of 1000 decodable frames): error 2, warning 1000.

## Fix

- `base_processor_caller.dart` `_processResponseData`: the first
  undecodable response closes the response controller and stops the chunk.
- `_handleResponse`: data that arrives after the controller is closed is
  dropped undecoded and reported once per call (`_warnedLateResponse`, in
  `base_processor.dart`).

## After

```
shape    n      more   consumer saw   log records
server   1000   no     1 error        error 2
server   1000   yes    1 error        error 2, warning 1
bidi     1000   yes    1 error        error 2, warning 1
```

P-317 re-run: every row unchanged.

## Canary

Witness `packages/core/rpc_dart/test/streams/a_hostile_response_is_logged_once_test.dart`:

- First half off (`if (1 < 0)` on the close and the return): "WITNESS a
  chunk of undecodable responses logs one decode error" failed with
  `Expected: an object with length of <1> ... Which: has length of <100>`.
- Second half off: "WITNESS responses after a failed decode are reported
  once" failed with `Which: has length of <100>`.
- GUARD "a valid response stream logs nothing at warning" green in both.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2220 ~1, http +261, http2 +320, websocket +331, isolate +102,
conformance +512 ~150); `format:check` SUCCESS; `license:check` compliant.

## Siblings

- unary: clean — P-321 unary arm, n=1000: error 2 before the fix
- client: fixed here — the shared caller processor, the path the server and bidi arms measure
- server: fixed here
- bidirectional: fixed here
- caller: fixed here
- responder: clean — `r854_responder_log_volume.dart`, 1000 undecodable then END_STREAM and 1000 more: debug 5, nothing at warning (decode failures log at internal, behind the guard)
- channel: fixed here — P-321 runs on `RpcChannelTransport`
- websocket: fixed here — its caller is an `RpcChannelTransport`, P-321's path
- isolate: fixed here — `RpcChannelTransport`, as websocket
- wasm: fixed here — `RpcChannelTransport`, as websocket
- http: fixed here — the http caller hands its whole body to the same processor as one payload (`rpc_http_caller_transport.dart`, one DATA message after `_readBounded`), the shape P-321 feeds; not measured on http itself
- http2: clean — `r854_http2_log_volume.dart`, 1000 bad then 1000 good from a raw h2 peer: error 3 with the fix off, error 2 and warning 1 with it on; the transport hands frames up one at a time and the endpoint cancels after the first

## Not fixed

- The sweep's remaining candidates: the http2 caller's DATA END_STREAM and
  `onDone` partial-frame paths, the http caller's `_readBounded` without an
  idle timeout (a call with no deadline waits on a stalled body as gRPC
  does), malformed DATA not counted toward the http2 caller's strike limit.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Bench
`../probes/P-321-log-records-per-hostile-response-chunk.md`, and
`../probes/P-317-what-a-channel-caller-accepts-from-a-hostile-server.md`
(reused for the regression check). Negative
`../checked/C-88-a-streaming-call-sends-nothing-before-its-first-listen.md`.
Round `853-a-unary-response-with-trailing-bytes-is-an-error.md`.
