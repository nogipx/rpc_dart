---
status: open
round: (not re-measured)
commit: acade03e
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
probe:
reason: risk — seen while porting the websocket tests to RpcClientConnection in major-release step 2, not measured
rank: 5
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
