---
round: 754
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-08
bench: P-259 — new
commit: yes
release: changelog
---

# Round 754 — a silent h2 peer reads online

## Target

B-269, STALE in `next`: `connect()` returns before the peer's SETTINGS.
Round 748 bounded the flapping it caused; the lead's other question was
never measured. Taken after round 753 because it is that round's shape on
another transport, and a peer that accepts and stays SILENT had not been
tried at all. The sibling bound exists: round 361 made websocket's
`connectTimeout` cover the whole open.

Scope, counted before the fix: every path to a connection goes through
`_guardedConnection`, 5 call sites — `connect` direct and via proxy,
`secureConnect` direct and via proxy, `viaSocket`. Reconnects reuse the
same factories.

## Hypothesis

Against a peer that accepts TCP and never speaks h2, the connection reads
Online and healthy for good, and a call without a deadline never ends.

## Before

```
                       refuse        acceptclose    silent
  Online emitted       1 (self-conn) 4              1, and it stays
  call made at Online  14 / 27 ms    14 / 32 ms     STILL WAITING at 8 s
  health then          unhealthy     unhealthy      healthy
  factory calls        4             4              1
```

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/r754_online_before_settings.dart`

## Mechanism

`connect()` returns when the socket opens and nothing waits for the peer's
SETTINGS, so `connectTimeout` stops at TCP and TLS.

## Fix

`_guardedConnection` arms a timer for `connectTimeout` (the default 30 s for
`viaSocket`) and destroys the socket if the peer's first SETTINGS have not
arrived; the connection then ends the usual way. Cancelled on SETTINGS and
on the socket's end. `connect()` returns as before: waiting for SETTINGS in
it would add about half a round trip to every first call, a speed trade the
owner has not been asked. `connectTimeout: null` keeps it unbounded. README
row and the constant's doc updated.

## After

```
  silent, connectTimeout 2 s:
    call made at Online    14 after 2009 ms
    health then            unhealthy
    the connection         Offline at 2037 ms, reconnects, same again
  closed before SETTINGS (r754_close_early.dart): process exits in 1.1 s
```

## Canary

Two halves, two canaries.

- Timer off: `WITNESS a call to a peer that never sends SETTINGS ends`
  failed with `Actual: 'still waiting after 5 s'`; P-259 `silent` read
  `STILL WAITING at 8 s`, `health then: healthy`.
- Cancel on SETTINGS off: `GUARD a live connection outlasts the SETTINGS
  bound` failed with `RpcStatusException(14): Transport is disconnected`.
- Cancel on the socket's end off: `r754_close_early.dart` held the process
  30.97 s, against 1.1 s with it.

## The verdict questions

1. Yes: `acceptclose` and `silent` differ only in whether the peer closes.
2. Yes: 14 in 32 ms against still waiting at 8 s.
3. In `RpcClientConnection`'s state callback, the caller's status and the
   transport's own `health()`.
4. n/a, not a zero.
5. Quoted above.
6. Three canaries, one per mechanism.
7. From the tables.
8. B-267, B-270 not taken, left open. Nothing dismissed on text.
9. None.
A1. n/a: the peer is the only party.
A2. Latency: the bench introduces it with a real socket server that holds
    the connection.
L1. n/a: no refusal.

## Gate

`melos run analyze`, `test:unit` (http2 310, rpc_dart 2110),
`format:check`, `license:check`: green.

## Not fixed

`viaSocket` takes no `connectTimeout`, so its bound is the 30 s default.
The early Online before SETTINGS stays, bounded by the timer and by the
backoff; its websocket twin is B-268, awaiting the owner.

## Links

Lead `../backlog/B-269-an-accept-and-close-endpoint-flaps-online.md` closed.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [..., 754]`.
New bench `../probes/P-259-a-peer-that-never-sends-settings.md`.
