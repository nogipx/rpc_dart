---
round: 755
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-08
bench: P-260 — new
commit: yes
release: breaking
---

# Round 755 — websocket connect had no default bound

## Target

Round 754's shape, a peer that accepts TCP and stays silent, run against
the siblings (L-12). The http/1.1 caller has no connection state, so a
silent server there is a slow server and the call's deadline bounds it.
The websocket caller has `connect()` and a connection state, and its
`connectTimeout` defaulted to null, where http2's is 30 s (round 563).

The two open leads were not taken. B-267 was re-read on today's code:
without the shared total, `RpcResponderBufferBudget.take` bounds by its own
`connectionBytes` and the channel transport's ledger by its own
`limitTotalBytes`, so the worst case is twice the window, bounded, and only a
hostile server against a client with responders reaches it. B-270 is being
captured by an unfiltered `test:web` run alongside this round.

## Hypothesis

With the defaults, `connect()` to a silent peer never returns, and an
`RpcClientConnection` built on it stays Connecting with no retry.

## Before

```
  default (omitted)        STILL PENDING at the 10 s cap
  bounded (2 s)            TimeoutException after 2017 ms     <- control
  conn, defaults           Connecting at 10 s, 1 attempt, 1 socket
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/r755_silent_peer.dart`.
Before the fix an omitted parameter and an explicit null were the same value.

## Mechanism

dart:io bounds only the TCP connect; nothing bounds the HTTP upgrade
response. The doc said the OS gives up; it does not.

## Fix

`connect()` defaults `connectTimeout` to 30 s, as the http2 caller; an
explicit null still waits without a bound. It also bounds every reconnect,
which reuses the same factory. Doc and README row rewritten.

## After

```
  default (omitted)        TimeoutException after 30031 ms
  null                     STILL PENDING at the 40 s cap        <- opt-out kept
  conn, defaults, 70 s     Connecting, retried at 30022 and 60373 ms, 3 sockets
```

## Canary

`with no connectTimeout given, a black hole is given up on`, with the
default put back to null, failed with:

```
  Expected: 'bounded'
    Actual: 'STILL HANGING at 40 s: no default bound'
```

## The verdict questions

1. Yes: `bounded` and `default` differ only in the bound given.
2. Yes: 2017 ms against still pending.
3. In the transport's own `connect()` and `RpcClientConnection`'s state
   callback; attempts counted as sockets the server accepted.
4. n/a, not a zero.
5. Quoted above.
6. One mechanism.
7. From the tables.
8. B-267 set aside on today's code (above), not on its text; B-270 left
   to the run in progress. The http/1.1 caller set aside by reading its
   API: it has no connect or connection state to hang.
9. None.
A1. n/a: the peer is the only party.
A2. Latency: a real socket server holds the connection.
L1. The refusal is the bound under test: its message names the connect
    and the time.

## Gate

`melos run analyze`, `test:unit` (websocket 294 with the new 30 s
witness), `format:check`, `license:check`: green. `test:web`, unfiltered for
B-270: green, `echo_worker_test.dart` passed.

## Not fixed

`openWebSocket` keeps a null default; it is the low-level opener and
`connect()` passes its own value. The witness waits the real 30 s, the one
slow test in the suite.

## Links

Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [..., 755]`.
New bench `../probes/P-260-a-silent-peer-and-the-websocket-defaults.md`.
Round 754 found the shape; round 563 set http2's default.
