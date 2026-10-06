---
round: 668
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-19
bench: P-231 — reused
commit: yes
release: changelog
---

# Round 668 — one dropped request retired the connection

## Target

B-246, filed by round 667's sweep: the HTTP/1.1 caller's `_emitError` puts each
request's failure on `incomingMessages` un-marked, and `RpcClientConnection`
retires the transport on it. One site; it was the last writer 667 counted.

## Hypothesis

A failure of one request (its socket dropped) fails every other call in flight
through `RpcClientConnection`, as one RST did on http2.

## Before

P-231's third arm rebuilt for HTTP/1.1:
`rpc_dart_http/.dart_tool/probe/b246_one_request_failure.dart`. A TCP proxy in
front of `RpcHttpServer` destroys any connection whose request names `/Svc/Die`;
three slow calls are in flight on their own sockets.

```
KILLED    dying call -> status 14; innocent -> [14, 14, 14]
CONTROL   dying call -> ok;        innocent -> [ok, ok, ok]
```

## Mechanism

Every call is its own HTTP request on its own pooled socket, so a failure of one
says nothing about the others. `RpcClientConnection` cannot know that, sees a
non-advisory error, and closes the transport under all of them.

## Fix

The broadcast copy of an `RpcStatusException` is a private
`_OneRequestFailure`, the same status, message and details, marked
`IRpcAdvisoryChannelError`. The failing call's own stream still gets the
original error. A foreign (non-status) error passes through unchanged; nothing
on this path produces one today, since `_asRpcStatus` maps `ClientException`.

Cost, stated: a server that is down no longer flips `RpcClientConnection`
offline through a failed call. On HTTP/1.1 that flip was a blip anyway -- the
factory builds a transport without touching the network, so the connection was
back online at once -- and every new call still fails UNAVAILABLE on its own.

## After

```
KILLED    dying call -> status 14; innocent -> [ok, ok, ok]
```

## Canary

`packages/transport/rpc_dart_http/test/one_failed_request_spares_the_other_calls_test.dart`,
marker off: `Expected: ['ok', 'ok', 'ok'] Actual: ['status 14', 'status 14',
'status 14']`. Restored: green.

## The verdict questions

1. Yes: the marker alone; the control sends `/Svc/Die` through untouched.
2. Yes: `[14,14,14]` against `[ok,ok,ok]`.
3. Yes: call outcomes at the caller.
4. Not zero-valued.
5. Yes, quoted.
6. One half, one canary.
7. Yes.
8. None.

## Gate

`analyze` (21 packages and wasm) green; `test:unit` green in all 15 packages
(rpc_dart_http +217); `format:check` clean; `license:check` compliant.

## Not fixed

Nothing on B-246. Every writer round 667 counted is now marked.

## Links

Lead `../backlog/B-246-an-http1-request-failure-retires-the-client-connection.md` closed.
Bench `../probes/P-231-one-stream-error-against-the-calls-beside-it.md` (arm added).
Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` -- `applied: [..., 668]`.
