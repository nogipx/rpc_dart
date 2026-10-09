---
round: 751
verdict: FIXED
packages: [rpc_dart]
lens: RPC-09
bench: P-255 — new
commit: yes
release: changelog
severity: S2
---

# Round 751 — deadline bounds the reconnect wait

## Target

`loop.py next` listed RPC-09 (a call deadline that sits below a wait) as swept
in round 743 with its paths moved since. One of the moves is round 750's own
fix: the proxy's `reconnect()` behind `RpcClientConnection` now waits up to
5 s for the connection's next attempt. `RpcRetryInterceptor` awaits that
`reconnect()` before a retry.

## Hypothesis

`_reconnectIfConnectionIsGone` awaits `transport.reconnect()` with neither the
call's deadline nor its cancellation, so a call behind the connection is held
up to 5 s past either.

## Before

P-255, at `4c32a82b`:

```
  connection, deadline 1 s      RpcDeadlineExceededException   5108 ms
  connection, cancel at 300 ms  RpcCancelledException          5103 ms
  bare, reconnect 3 s, deadline 1 s                            3109 ms
  bare, reconnect 3 s, cancel at 500 ms                        3105 ms
```

Control, `client_connection.dart` from `ef95cff2^`: 206 and 203 ms. The hold
is round 750's.

## Mechanism

The interceptor's backoff already stopped at the deadline and at a cancel;
the reconnect after it did not. Before round 750 the proxy answered at once,
so only a bare transport with a slow reconnect could show it.

## After

`_withinCall` races `reconnect()` against the call's remaining time and its
token's `cancelled`; the reconnect runs on.

```
  connection, deadline 1 s       996 ms
  connection, cancel at 300 ms   301 ms
  bare, deadline 1 s             997 ms
  bare, cancel at 500 ms         501 ms
  bare, no deadline             6209 ms   (both reconnects waited for, as before)
```

## Canary

`test/resilience/a_reconnect_waits_no_longer_than_the_call_test.dart`, with
the interceptor from `4c32a82b`:

```
  held past the deadline: 5110 ms
  held past the cancel: 5105 ms
```

Its GUARD (no deadline: the reconnect is waited for) passes on both.

## Gate

`analyze`, `test:unit`, `format:check`, `license:check`, `check:skills`.

## Not fixed

Nothing. The two other callers of `reconnect()` in `lib/`,
`RpcEndpoint.reconnect()` and rpc_notify's router `reconnect()`, are explicit
operations with no call context to bound them; the wait they see is the
proxy's own 5 s.

## Links

Round 750 introduced the wait; L-22.
