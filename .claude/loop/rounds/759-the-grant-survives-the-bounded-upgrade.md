---
round: 759
verdict: CLEAN
packages: [rpc_dart_websocket]
lens: RPC-20
bench: P-262 — new
commit: yes
release: none
---

# Round 759 — the grant survives the bounded upgrade

## Target

RPC-20, rank 1, against code this session wrote: round 756's
`connectBounded`, which detaches the socket after the 101 and re-wraps it.
The server sends its connection-window grant the moment the upgrade
completes, so a frame read together with the 101 or before the first
listener is exactly what this lens has lost before (rounds 373, 574, 704);
a lost grant leaves flow control off and every suite green. B-267, B-270
not taken.

## Hypothesis

A client opened through `connectBounded` loses the server's first frame, and
its connection credit stays `null`.

## Before

```
  arm       client connection credit, 5 connections
  bounded   67108864 x 5
  plain     67108864 x 5      (dart:io WebSocket.connect)
  gap       67108864 x 5      (200 ms before the first listener)
  nogrant   null x 5          (server advertises no window: the control)
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/r759_grant_after_upgrade.dart`

## Mechanism

Bytes after the 101 stay with the detached socket, and dart:io's WebSocket is
single-subscription, so a frame that arrives before the first listener is
held rather than dropped.

## After

n/a — nothing changed.

## Canary

n/a — no fix. The `nogrant` arm is the control that shows the reading can
come back `null`.

## The verdict questions

1. Yes: `nogrant` differs only in the server sending no grant.
2. Yes: `null` against 67108864.
3. In the client transport's own `flowControlConnectionCredit`.
4. Not a zero; the `null` arm shows the observable can report absence.
5. n/a, no fix.
6. n/a.
7. CLEAN with a valid control.
8. Nothing set aside on prose: the target is this session's own code.
9. None.
A1. n/a.
A2. Latency: the `gap` arm holds the listener off for 200 ms.
L1. n/a.

## Gate

n/a — no code change.

## Not fixed

Nothing.

## Links

Lens `../lenses/RPC-20-the-window-before-the-first-listener.md` — `applied: [..., 759]`.
New bench `../probes/P-262-a-grant-after-the-bounded-upgrade.md`; P-195's observable.
Round 756, the code under test.
