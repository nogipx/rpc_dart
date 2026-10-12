---
round: 870
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-19
bench: none — the witness is the lifecycle model's pinned cell, which shrinks and replays the sequence itself
commit: yes
severity: S2 — "a status or error type a caller branches on"
release: changelog
---

# Round 870 — a request after the server's end keeps its status on http2

## Target

B-283, the lifecycle model's one KNOWN FAILING cell, STALE after 12 of its
files moved in rounds 853-863. Re-measured before anything else, since
those rounds rewrote the paths it names. Taken over a first look at a
caller middleware rejecting a single request (unary, server stream), whose
probe had no control able to show a half-open server stream and was not
recorded.

## Hypothesis

A request a bidi caller sends after the server has ended the call (its
response paused, the ABORTED trailer not yet read) leaves the server's
status as the call's outcome, as on the other transports. Fails if the
call ends with a different status.

## Before

```
lifecycle_model_test --run-skipped, "pinned send after the handler failed, response paused":
  start c0 bidi fail delay=17 count=3; pause c0; wait 52; send c0
  channel, http, websocket, isolate: pass
  http2: ended 57 ms with RpcStatusException(9): Stream 3 not found. Send metadata first.
         (expected the handler's ABORTED); shrunk 4 -> 4 operations, deterministic
  wasm: harness unsupported (outside the workspace)
```

## Mechanism

When the server's trailer ends the stream, the http2 caller transport's
`onDone` removes it from `_activeStreams`. The caller's next
`sendMessage` on that id then threw FAILED_PRECONDITION "Stream not found";
the bidi bridge turned the send failure into the call's error, which
reached the consumer before the paused ABORTED it never got to read.
RPC-19: a missing stream meant both "never opened" (a programming error)
and "the peer has ended it" (an ordinary race).

## Fix

`rpc_http2_caller_transport.dart`: a set of ids the peer ended, filled in
`onDone`, cleared by `releaseStreamId`, on close and on reconnect;
`sendMessage` on one of them drops the send. An id never opened still
throws.

## After

```
the same cell: http2 passes; the other cells unchanged
lifecycle model in the gate: +513 ~149 (was +512 ~150: the cell left _knownFailing)
```

## Canary

The cell removed from `_knownFailing` in
`packages/test/rpc_dart_conformance/test/lifecycle_model_test.dart`; with
the drop switched off it fails as before: `[ending] expected the
handler's ABORTED, got status 9 ... Stream 3 not found. Send metadata
first.` Restored: green.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(conformance +513 ~149, http2 +358, rpc_dart +2231 ~1, http +261,
websocket +331, isolate +102); `format:check` SUCCESS; `license:check`
compliant.

## Siblings

- http2: fixed here
- channel: clean — `lifecycle_model_test.dart`, the same pinned cell passes
- http: clean — `lifecycle_model_test.dart`, the same pinned cell passes
- websocket: clean — `lifecycle_model_test.dart`, the same pinned cell passes
- isolate: clean — `lifecycle_model_test.dart`, the same pinned cell passes
- wasm: n/a — the model's wasm member is unsupported in the workspace (covered by `test:wasm`); its caller is an `RpcChannelTransport`, the channel cell's path
- caller: fixed here
- responder: n/a — the responder does not send requests
- bidirectional: fixed here
- client: read — the fix sits in the http2 transport's `sendMessage`, below every shape; `lifecycle_model_test.dart`'s seeded http2 cells pass, but none was checked to contain a client-stream send after a failure
- server: n/a — one request, sent before any response
- unary: n/a — one request, sent before any response

## Not fixed

—

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md`. Lead
`../backlog/B-283-a-request-sent-after-a-paused-http2-call-failed-loses-its-status.md`.
