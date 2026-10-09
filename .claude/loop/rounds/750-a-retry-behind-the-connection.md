---
round: 750
verdict: FIXED
packages: [rpc_dart]
lens: RPC-08
bench: P-254 — new
commit: yes
release: changelog
severity: S2
---

# Round 750 — a retry behind the connection

## Target

The two halves of the client's resilience, together: `RpcRetryInterceptor`
on an endpoint over `RpcClientConnection`, through a server restart. The
interceptor reconnects the transport before retrying UNAVAILABLE; behind the
connection, the transport is the connection's proxy. Rounds 746-748 changed
that proxy's drop handling.

## Hypothesis

A retry behind the connection does worse than one on a bare transport,
because the proxy's `reconnect()` cannot reconnect.

## Before

P-254, 600 ms outage, 5 runs each:

```
  bare  ok at 864, 1157, 711, 682, 991 ms                     5 of 5
  conn  FAILED 14 at 1553 ms; ok at 1726, 2027, 946, 1368 ms   4 of 5
```

The failed run ended after the server was back (600 ms) and inside the retry
budget.

## Mechanism

The proxy's `reconnect()` returned `degraded: reconnect is managed by
RpcClientConnection` and did nothing. A retry therefore went out whenever its
jittered backoff ended. If that was inside the connection's own backoff gap,
the call failed at once with "reconnecting; retry". With all five retries in
such gaps, the call lost even though the server was up. On a bare transport,
`reconnect()` connects before each retry.

## Fix

The proxy's `reconnect()` waits, up to 5 s, for the outcome of the
connection's next attempt, read off its state stream (`ef95cff2`). It starts
no attempt: waking the loop per retry would turn every caller's retry into a
connect against a server that is down.

## After

```
  conn, 600 ms outage, 8 runs   ok at 801, 797, 798, 1192, 1003, 806, 1108, 802 ms
```

The connection attempt lands at about 750 ms, and each retry now follows it.

## Canary

`awaitReconnect` unwired: the witness reads `Expected: unhealthy, Actual:
degraded`, and the online guard `Expected: true, Actual: false`. The second
shows the old `reconnect()` answered degraded on a live connection too.

## The verdict questions

1. Yes: the recommended client setup, a real restart.
2. Yes: `bare` passes every run at the same outage.
3. At the caller.
4. A rate over random backoff, so stated as runs, not a single figure.
5. Quoted.
6. One mechanism.
7. A trade: `reconnect()` on the connection's transport can now take up to
   5 s where it returned at once. Only a caller that asks waits.
8. None.
A1. A server restart shorter than the retry budget.
A2. Calls that fail during a restart.
L1. With default settings the retry budget covers about 1.5 s of outage on
average (full jitter over 200, 400, 800, 1600 ms). Longer outages still
surface UNAVAILABLE by design: 2 of 3 at 2.5 s.

## Gate

`analyze`, `test:unit`, `format:check`, `license:check`, `check:skills`.

## Not fixed

Nothing.

## Links

Lens `../lenses/RPC-08-policy-field-single-transport.md`.
New bench `../probes/P-254-a-retry-through-a-server-restart.md`.
