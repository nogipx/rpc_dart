---
round: 748
verdict: FIXED
packages: [rpc_dart]
lens: RPC-19
bench: P-252 — new
commit: yes
release: changelog
---

# Round 748 — a connection that drops at once

## Target

B-269, filed by round 746: does each premature Online reset the reconnect
backoff? `_connectWithBackoff` set `_reconnectAttempts = 0` on every attach,
and a drop added one. A connection that drops at once therefore always waits
the base delay. The case is not only http2 before its SETTINGS:
`RpcWebSocketServer` at `maxConnections` completes the upgrade and then
closes, and that is the moment the server is overloaded.

## Hypothesis

Against a server that accepts and refuses, the client reconnects at the base
delay for ever and never reaches `maxAttempts`.

## Before

P-252, 200 ms base, no jitter, `maxAttempts: 4`, 6 s:

```
  refuse  factory calls 28, online 28 times, gave up: false
  down    factory calls 4,  online 0 times,  gave up at 1452 ms
```

## Mechanism

One state with two readers. To the connection, `RpcClientOnline` means the
factory returned a transport. To the backoff, it meant "the server is
serving", and it started the count over on that.

## Fix

The count starts over when a connection that lasted at least 5 s drops, not
at attach (`3fc2fa74`). `connect()` and `forceReconnect()` still reset it:
those are the caller asking. The skill states the rule.

## After

```
  refuse  factory calls 4, online 4 times, gave up at 1502 ms
```

## Canary

- reset at attach restored: `still reconnecting after 102 connections that
  each dropped at once`
- stability reset removed: the guard reads `Expected: [1, 2, 3, 2, 3]`,
  `Actual: [1, 2, 3]`. The guard's first form had no failures before the
  long-lived connection and passed both ways; it was rebuilt to fail twice
  first.

## The verdict questions

1. Yes: the shipped server's own refusal.
2. Yes: `down` gives up after 4; `refuse` matches it after the fix.
3. In the connection's factory count and state stream.
4. Not a performance claim.
5. Quoted.
6. One mechanism.
7. A trade: a server that restarts within 5 s of every connect now backs off
   further than before. The threshold is a constant, not a policy field.
8. B-269's remaining half.
A1. A server at capacity, or a balancer with no backend.
A2. Reconnect rate against an overloaded server.
L1. n/a.

## Gate

`analyze`, `test:unit`, `format:check` (it caught round 747's unformatted
test, fixed in `9d33e70b`), `check:skills`.

## Not fixed

B-269's other half: `RpcHttp2CallerTransport.connect()` reports a transport
before the server's SETTINGS, so Online can still be reported for a socket
that never serves. Its cost is now bounded by the backoff.

Round 746-748 test headers and two lib comments had been written as history;
corrected in `4dd9cd0f`, `c60e9581`, `6930c014`.

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` — `applied: [..., 748]`.
New bench `../probes/P-252-a-server-that-accepts-and-refuses.md`.
Lead `../backlog/B-269-an-accept-and-close-endpoint-flaps-online.md`.
