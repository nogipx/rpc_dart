---
round: 667
verdict: FIXED
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-19
bench: P-231 — new
commit: yes
release: changelog
---

# Round 667 — one stream's error failed every call beside it

## Target

Found while measuring B-189. The responder pipeline's `incomingMessages` onError
answers every active stream, and the http2 responder puts per-stream errors on
that broadcast. RPC-19's round-353 question, asked of a reader 353 did not
enumerate: list what can be put on the signal and ask whether the reader's one
interpretation fits each.

Scope, counted before the fix. Readers that act connection-wide on a broadcast
error: the responder pipeline, the unary responder's listener (both answer every
call; both skip `IRpcAdvisoryChannelError`) and `RpcClientConnection` (retires;
skips advisory and `RpcFrameException`). Writers of a one-stream error to a
broadcast: the http2 responder (2 sites), the http2 caller (4 sites, plus 2 that
mean the connection failed), `RpcChannelTransport._validateInbound` (1), the
http1 caller (1). The first three are in scope; the http1 caller is filed.

B-189 itself is measured below and left open.

## Hypothesis

A stream-scoped error arrives un-marked, so each reader treats it as the
connection's death.

## Before

```
http2 responder, frame with compression flag 2   innocent [13, 13, 13]
channel responder, 20 headers vs maxHeaders 8    innocent [3, 3, 3]
http2 RpcClientConnection, server RSTs one call  innocent [14, 14, 14]
controls, offending stream clean                 innocent [ok, ok, ok]
```

## Mechanism

http2 wrapped every stream error in `RpcHttp2StreamError`, whose own doc says the
envelope means stream-scoped and connection errors go unenveloped -- the code
enveloped both, and nothing marked either. The channel transport put its
`RpcFrameException.policy` on the broadcast; `RpcClientConnection` exempts that
type, the endpoints do not.

## Fix

- http2: `RpcHttp2OneStreamError extends RpcHttp2StreamError implements
  IRpcAdvisoryChannelError`, not exported. `_emitStreamError` uses it unless
  `connectionWide: true`, which the two connection-failure sites on the caller
  and the unknown-error site on each side pass.
- channel: the violation is a private `_OneStreamViolation`, an advisory
  `RpcFrameException.policy`. The offending stream still gets its
  INVALID_ARGUMENT from the transport; consumers matching `RpcFrameException`
  are unaffected.

## After

All three innocent arms `[ok, ok, ok]`; the offending stream is still answered
(RESOURCE_EXHAUSTED on http2, INVALID_ARGUMENT on the channel).

## Canary

Three halves, three canaries:

- http2 responder marker off:
  `one_stream_error_spares_the_other_calls_test.dart` red, `Expected: ['ok',
  'ok', 'ok'] Actual: ['status 8', 'status 8', 'status 8']`.
- http2 caller marker off: the same file's connection test red, `Actual:
  ['status 14', 'status 14', 'status 14']`.
- channel marker off: `one_refused_request_spares_the_other_calls_test.dart`
  red, `Actual: ['status 3', 'status 3', 'status 3']`.

All restored: green.

## B-189, measured on the way

```
one unary call      end-of-stream events: caller 2, responder 2   (claim 1 confirmed)
bidi, server ends   responder cancel frame for the released id 1  (claim 4 confirmed)
own resetStream     caller ERROR records +0                       (claim 3 refuted)
```

Claim 2 (an error then a synthesised status) is not measured. Recorded in the
lead; no fix here.

## The verdict questions

1. Yes: each canary switches one marker; the control sends the same stream clean.
2. Yes: `[13,13,13]`, `[3,3,3]`, `[14,14,14]` against `[ok,ok,ok]`.
3. Yes: call outcomes at the caller.
4. Not zero-valued.
5. Yes, quoted above.
6. Yes, three.
7. Yes.
8. None. The axis miss is L-12's second half (a sweep enumerated one reader of
   the signal and not the other), already written.

## Gate

`analyze` (21 packages and wasm) green; `test:unit` green in all 15 packages
(rpc_dart +2056, rpc_dart_http2 +284); `format:check` clean; `license:check`
compliant.

## Not fixed

The http1 caller's `_emitError`, 1 site: filed as `B-246`, because which http1
failures mean the server is gone is a per-exception question nobody has
measured. B-189 stays open with three of four claims measured.

## Links

Bench `../probes/P-231-one-stream-error-against-the-calls-beside-it.md`.
Lead filed `../backlog/B-246-an-http1-request-failure-retires-the-client-connection.md`.
Lead measured `../backlog/B-189-http2-terminal-events-are-delivered-twice.md`.
Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` -- `applied: [..., 667]`.
