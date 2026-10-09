---
round: 753
verdict: DEFERRED
packages: [rpc_dart_websocket, rpc_dart]
lens: RPC-19
bench: P-258 — new
commit: yes
release: none
---

# Round 753 — online before the handshake

## Target

B-268, rank 2, STALE in `next`: its text described code that has moved, and
round 752 left it open without re-measuring. B-270 (rank 1) needs repeated
browser runs to catch an intermittent load error; B-268 has a bench to reuse
and a consequence nobody had measured. P-251 re-run first: `health right
after construction: healthy`, then `closed`, 0 uncaught errors. The crash is
fixed; the early healthy remains.

## Hypothesis

A factory that returns the constructor's transport over an unconnected
channel makes `RpcClientConnection` emit Online for a server that does not
exist, and a call made then hangs or fails.

## Before

```
                            ctor            ready (control)
  Online emitted            4               0
  call made at Online       status 14 after 23 ms
  factory calls             4               4
  final state               Disconnected    Disconnected
  uncaught errors           0               0
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/r753_online_before_ready.dart`

## Mechanism

`RpcClientConnection` emits Online when the factory returns and asks the
transport nothing; the constructor's transport is healthy until the channel's
failure closes it, 5-25 ms later.

## After

n/a — deferred.

## Canary

n/a — deferred.

## The verdict questions

1. Yes: the arms differ only in `await channel.ready`.
2. Yes: Online 4 against 0.
3. In `RpcClientConnection`'s own state callback and the caller's status.
4. n/a, not a zero.
5. n/a, no fix.
6. n/a.
7. DEFERRED for an owner decision: the fix is new core API and a new wait on
   every connect, against a measured cost of false Online events and a call
   failing in 23 ms with a retryable status, bounded by `maxAttempts`.
8. The severity call rests on this round's table, not on B-268's text. B-267,
   B-269 and B-270 were not taken and stay open.
9. None.
A1. n/a: no attacker.
A2. Neither: the gap is the handshake failing, which the bench causes.
L1. n/a: no refusal.

## Gate

n/a — no code change.

## Not fixed

The early Online and the early healthy. B-268 is now `awaiting owner` with
the question: a readiness capability in core, a README line, or leave it.

## Links

Lead `../backlog/B-268-a-constructed-websocket-transport-reports-online-early.md`.
Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` — `applied: [..., 753]`.
New bench `../probes/P-258-online-before-the-handshake.md`; P-251 re-run.
