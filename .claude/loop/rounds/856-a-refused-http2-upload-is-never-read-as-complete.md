---
round: 856
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-19
bench: P-323 — reused
commit: yes
severity: S1 — "data lost, corrupted, duplicated or delivered to the wrong call"
release: changelog
---

# Round 856 — a refused http2 upload is never read as complete

## Target

B-294, filed in round 855 from P-323: after the http2 responder refuses a
request that ended mid-frame, the client-stream handler still ran to
completion on the messages before the cut. Taken first because an upload
handler that commits what it collected commits a truncated upload while
the client is told the call failed.

Measured on core first (P-324): a client cancel mid-upload over the
channel transport reaches both upload handlers as `RpcCancelledException`,
and `finish` reads DONE [a, b]. So core keeps RPC-12's contract and the
defect is in the http2 refusal path.

## Hypothesis

A request the http2 responder refuses never reaches an upload handler as a
complete request stream. Fails if the handler's `toList()` returns.

## Before

```
P-323 with handlers recording DONE or ERROR (fix of round 855 in place):
END on the DATA      collect whole + 3 bytes   grpc=13  handler DONE []
                     chat    whole + 3 bytes   grpc=13  handler DONE []
END on trailers      collect whole + 3 bytes   grpc=13  handler DONE [x]
                     chat    whole + 3 bytes   grpc=13  handler DONE [x]
END on empty DATA    collect whole + 3 bytes   grpc=13  handler ERROR RpcCancelledException
whole (control)      every shape               grpc=0   handler DONE [x]

P-324 (core, channel pair):
collect finish  DONE [a, b]       collect cancel  ERROR RpcCancelledException
chat    finish  DONE [a, b]       chat    cancel  ERROR RpcCancelledException
```

## Mechanism

`_answerFramingViolation` sends the INTERNAL trailer, awaits it, and only
then emits the `x-client-cancelled` frame that tears the handler's request
stream down. The stream's `onDone` (the peer's END_STREAM) runs in between
and emits a plain end of stream, so the handler's `await for` finished
normally on what it had. RPC-19: the end of the stream meant "the request
is complete" and also arrived for a request already refused. A first
attempt, `_emitStreamError` before the refusal, moved nothing: that error
goes to the broadcast envelope, not into the handler's request stream.

## Fix

`rpc_http2_responder_transport.dart` / `_inbound.dart`:
`_answerFramingViolation` records the stream in `_requestRefused`
synchronously, and `onDone` emits no end of stream for a refused one, so
its request stream ends through the refusal's cancel alone. The set is
cleared in `releaseStreamId` and on close.

A second guard (dropping every later frame of a refused stream in
`_handleIncomingMessage`) was tried and removed: its canary, with an
over-limit frame followed by a separate END, changed no witness.

## After

```
P-323: no refused row reads DONE; collect and chat read ERROR
RpcCancelledException or never start; every whole row DONE [x]
```

## Canary

Witness `packages/transport/rpc_dart_http2/test/a_request_cut_mid_message_is_refused_test.dart`,
"WITNESS {collect, chat}, refused on {data, empty data, trailers}, never
reads its request as complete". With the `onDone` check off (`1 > 0 ||`):
`Expected: empty Actual: ['collect []']`, `['collect [x]']`, `['chat
[x]']` (3 of 6 in one run, 4 in another: the race the fix closes). Fix on,
three runs: all green. GUARD "a whole request reads it as complete" green
in every arm.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2220 ~1, http2 +358, http +261, websocket +331, isolate +102,
conformance +512 ~150); `format:check` SUCCESS; `license:check` compliant.

## Siblings

- http2: fixed here
- channel: clean — P-324: a cancel reaches both upload handlers as RpcCancelledException
- websocket: clean — `RpcChannelTransport`, the path P-324 measures
- isolate: clean — `RpcChannelTransport`, the path P-324 measures
- wasm: clean — `RpcChannelTransport`, the path P-324 measures
- http: read — the http responder hands the whole body to the pipeline in one message and refuses before dispatch (round 847, P-316: collect and chat grpc=3, handler not run)
- responder: fixed here
- caller: n/a — the caller does not run a handler on a request stream
- client: fixed here
- bidirectional: fixed here
- unary: n/a — one request message, no request stream for a handler to read
- server: n/a — as unary

## Not fixed

- B-292: unary and server-stream requests whose tail arrives in a later
  chunk are still dispatched on the first whole message.

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md`. Benches
`../probes/P-323-an-http2-request-cut-mid-message-per-shape-and-ending.md`,
`../probes/P-324-what-an-upload-handler-reads-when-the-client-cancels.md`.
Lead `../backlog/B-294-a-refused-upload-ends-its-handler-input-cleanly.md`.
Round `855-a-cut-http2-stream-is-an-error-on-every-ending.md`. Lens
`../lenses/RPC-12-cancel-into-request-stream.md` (the contract kept).
