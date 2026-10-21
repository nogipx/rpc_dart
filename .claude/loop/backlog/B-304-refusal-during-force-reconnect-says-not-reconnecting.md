---
status: closed (round 896)
round: 896
commit: 99126bfa
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
probe: P-348
reason: closed — REFUTED in round 896 (P-348): the window is the old transport's close, under 10 ms over a dead path on websocket, socket and http2, shorter than the retry's first 200 ms backoff; only a third-party transport with a slow close would show it
rank: 7
---

# B-304 — refusal during force reconnect says not reconnecting

`forceReconnect()` runs `_proxy.detach()` and only in its `.then` starts
`_connectWithBackoff()`. The proxy's `isReconnecting` reads `_connectingGuard`,
which that loop sets. So between the detach and the loop's start, a call the
proxy refuses gets `RpcNoConnectionException(reconnecting: false)` -- the
"not reconnecting, call connect()" text -- although a reconnect is about to
start. The status is UNAVAILABLE either way, so the default retry still
retries; what is wrong is the field and the message a caller branches on.

Unknown: whether `_awaitNextAttempt`, which `RpcRetryInterceptor` waits on
through `IRpcReconnectOutcome`, also returns at once in that window, which
would spend a retry attempt on a reconnect that has not started.

## Next step

Measure: a transport whose `close()` is slow (a completer the test holds),
`forceReconnect()`, then a call before the close completes. Record the
refusal's `reconnecting` and, with the retry interceptor, how many attempts
the call spends. Control: the same call after the loop has started.

## Owner decision

—
