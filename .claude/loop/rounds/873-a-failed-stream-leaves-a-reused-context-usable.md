---
round: 873
verdict: FIXED
packages: [rpc_dart]
lens: RPC-19
bench: none — found by a surviving mutant; the witness asserts the token directly
commit: yes
severity: S2 — "a status or error type a caller branches on"
release: changelog
---

# Round 873 — a failed stream leaves a reused context usable

## Target

The surviving-mutant detector on `caller_pipeline.dart` (the bidi bridge
rounds 861 changed) against `test/endpoint`, 15 of 95 mutants: 6
survivors. Four were the zero-copy unary path and codec checks, exercised
by `test/zero_copy`, outside the run. One, `:728` (`fromCancel &&
!finishedNaturally` to `||`, firing the call's token on any ending),
survived the full rpc_dart suite too. A witness for it, a reused
`RpcContext` after a failed bidi call, failed on the UNMUTATED code.

## Hypothesis

A streaming call the server fails leaves the caller's context (and its
cancellation token) usable for the next call. Fails if the token is
cancelled.

## Before

```
a_failed_bidi_call_leaves_a_reused_context_usable_test, consumer `toList()`:
bidi, server fails (ABORTED)          token cancelled: true
server stream, server fails           token cancelled: true
bidi / server stream, end OK          token cancelled: false
unary / client stream, server fails   token cancelled: false
```

The next call on that context then fails CANCELLED without anyone having
cancelled anything.

## Mechanism

`_bridgeCallerResponses` fires the context's token from `onConsumerCancel`
unless the call `finished`, and sets `finished` only in `onSourceDone`.
The comment there names the reused-context poisoning and guards normal
completion against it. An ERROR ends the call just as well, and every
consumer that reads with `await for` or `toList` cancels its subscription
at the error, so the token fired for a call the server had already ended.
RPC-19: `finished` meant "the source completed", read as "the call is
over".

## Fix

`caller_pipeline.dart` `_bridgeCallerResponses`: `onSourceError` marks the
call finished too. The server learns of a LOCAL failure from the callers'
own abort notices (rounds 626 and 861), whose witnesses stay green.

## After

```
every row of the witness: token cancelled: false; the next unary on the context answers
```

## Canary

`onSourceError` doing nothing: "WITNESS a bidi call the server fails ..."
and "WITNESS a server stream the server fails ..." both failed with
`Expected: false Actual: <true>`; the four GUARD rows green. Restored:
6 of 6, and `a_server_stream_that_fails_locally_tells_the_server_test`
6 of 6.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2237 ~1, http2 +358, http +261, websocket +331, isolate +102,
conformance +513 ~149); `format:check` SUCCESS; `license:check` compliant.

## Siblings

- bidirectional: fixed here
- server: fixed here
- unary: clean — `a_failed_bidi_call_leaves_a_reused_context_usable_test.dart`, unary row: token not cancelled, before and after
- client: clean — `a_failed_bidi_call_leaves_a_reused_context_usable_test.dart`, client-stream row: token not cancelled, before and after
- caller: fixed here
- responder: n/a — the token is the caller's context
- channel: fixed here — the witness runs on `RpcChannelTransport.pair`
- websocket: fixed here — the bridge is above the transport
- isolate: fixed here — the bridge is above the transport
- wasm: fixed here — the bridge is above the transport
- http: fixed here — the bridge is above the transport
- http2: fixed here — the bridge is above the transport

## Not fixed

- 80 of the file's 95 mutants were not run (`--limit 15`).

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md`. Rounds
`861-a-bidi-call-that-fails-locally-tells-the-server.md`,
`626-the-server-was-never-told.md`,
`872-the-caller-processors-surviving-mutants-are-not-defects.md`.
