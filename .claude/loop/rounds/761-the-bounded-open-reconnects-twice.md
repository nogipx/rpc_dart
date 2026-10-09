---
round: 761
verdict: CLEAN
packages: [rpc_dart_websocket]
lens: RPC-21
bench: P-263 — new
commit: yes
release: none
---

# Round 761 — the bounded open reconnects twice

## Target

RPC-21 against this session's own websocket changes: round 756's
`connectBounded` and round 755's 30 s default `connectTimeout`, both on every
reconnect, were measured on a first connect only. The lens asks for the
lifecycle driven twice and through a failure. B-267 and B-270 not taken.

## Hypothesis

A reconnect after a failed one, through the bounded open, leaves the
transport unable to recover, or recovers once and not twice.

## Before

```
  start              ok x
  cycle 1 down       reconnect unhealthy, call status 14
  cycle 1 up         reconnect healthy, call ok x, health healthy
  cycle 2 down       reconnect unhealthy, call status 14
  cycle 2 up         reconnect healthy, call ok x, health healthy
```

P-250 re-run as well: `conn` (RpcClientConnection) comes back after a server
restart, `ok x` in 3 ms; `direct` stays disconnected until `reconnect()` is
called, as its error says.

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/r761_reconnect_twice.dart`

## Mechanism

Each reconnect calls the same factory, which builds a fresh bounded open, so
nothing from the failed attempt carries into the next.

## After

n/a — nothing changed.

## Canary

n/a — no fix. The down phase is the control.

## The verdict questions

1. Yes: up and down differ only in whether the server runs.
2. Yes: status 14 against `ok x`.
3. In the transport's own `reconnect()` and `health()`, and the caller's
   status.
4. Not a zero.
5. n/a.
6. n/a.
7. CLEAN with a valid control.
8. Nothing set aside on prose: the target is this session's own code.
9. None.
A1. n/a.
A2. Neither: the event is the server going away, which the bench causes.
L1. n/a.

## Gate

n/a — no code change.

## Not fixed

Nothing.

## Links

Lens `../lenses/RPC-21-drive-the-lifecycle-twice.md` — `applied: [..., 761]`.
New bench `../probes/P-263-reconnect-through-a-failure-twice.md`;
`../probes/P-250-a-client-connection-across-a-server-restart.md` re-run.
Rounds 755 and 756, the code under test.
