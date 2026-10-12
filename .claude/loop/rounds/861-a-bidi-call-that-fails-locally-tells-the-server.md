---
round: 861
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-328 — new
commit: yes
severity: S1 — "memory or CPU a peer or ordinary use can grow without bound"
release: changelog
---

# Round 861 — a bidi call that fails locally tells the server

## Target

Network-audit KV-R-12 (per-call leaks) and I-6 (a cancel reaches the other
side), on the call ending round 854 touched: the caller fails a call on a
response it cannot decode. Round 626 fixed this for the server stream and
recorded bidi as already telling the peer ("cleanup(abortPeer: true)"); the
code's response-side `onError` calls `cleanup()` with no abort, so the
record was checked against the code first, then measured.

## Hypothesis

When a bidi call ends on a failure only the caller sees, the server's
handler stops, as it does for a server stream. Fails if the handler keeps
producing.

## Before

```
P-328, consumer listening with onError, the caller fails on the 3rd response:
shape    arm      handler, 1 s after the caller's error   cancel seen
server   decode   0 more                                  yes
server   control  0 more                                  yes
bidi     decode   80 more (and on, every 10 ms)           no
bidi     control  0 more                                  yes
```

The same with round 854's close-on-decode-error switched off: bidi 80 more,
so the defect predates it. A consumer that leaves with `await for` cancels,
fires the token and tells the server; one that takes the error with
`onError` and keeps listening never does.

## Mechanism

`_buildBidirectionalStream`'s response `onError` ran `cleanup()`, which
sends the abort notice only for `abortPeer` (set for a failed REQUEST side)
and fires the token only for `fromCancel` (a consumer cancel). A response
side that failed locally ran neither, and the handler kept yielding for a
call that had ended. The server-stream caller tells them apart by whether
the server sent its status (`serverEnded`, round 626); the bidi bridge had
no such record.

## Fix

`caller_pipeline.dart`: the bidi bridge records when a response carries
the server's status, and an error without one runs `cleanup` with
`abortPeer` (unless the token was already cancelled, which has told the
server), with the reason "bidirectional call abandoned locally".

## After

```
P-328 bidi decode: 0 more, cancel seen; control unchanged
```

## Canary

Witness `packages/core/rpc_dart/test/endpoint/a_server_stream_that_fails_locally_tells_the_server_test.dart`,
new rows "bidi: a response the caller cannot decode", "... middleware",
"bidi control", with the consumer now listening through `onError`. With
`abortPeer` forced false: "bidi: a response the caller cannot decode"
failed with `Expected: <0> Actual: <48>` "a bidi handler kept producing for
a call its caller ended"; the other rows green. Restored: 6 of 6.

The witness first used `await for`, as the server-stream rows do, and
passed with the fix off: that consumer cancels and fires the token. The
switch to `onError` is what made it see the defect.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2223 ~1, http2 +358, http +261, websocket +331, isolate +102,
conformance +512 ~150); `format:check` SUCCESS; `license:check` compliant.

## Siblings

- bidirectional: fixed here
- server: clean — P-328 server decode, 0 more (round 626's `serverEnded`)
- client: read — `ClientStreamCaller` sends `notifyPeerOfAbort` on a local failure (round 626's record); one response, so no handler stream is left producing
- unary: n/a — one response; the handler has finished when it is decoded
- caller: fixed here
- responder: n/a — the handler is the party being told; nothing changed there
- channel: fixed here — P-328 runs on `RpcChannelTransport.pair`
- websocket: fixed here — `RpcChannelTransport`, P-328's path
- isolate: fixed here — `RpcChannelTransport`, P-328's path
- wasm: fixed here — `RpcChannelTransport`, P-328's path
- http2: clean — P-328's http2 copy, fix off: 0 more, cancel seen (closing the stream resets it)
- http: fixed here — the bridge is shared by every transport; not measured on http, whose caller sends the abort as it sends any cancel

## Not fixed

- Round 626's record says bidi already told the peer; that held for the
  request side only. Left as written; this record corrects it.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Bench
`../probes/P-328-does-a-local-decode-failure-reach-the-server.md`. Rounds
`626-the-server-was-never-told.md`, `854-a-hostile-response-is-logged-once.md`.
