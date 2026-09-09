---
round: 238
verdict: CLEAN
packages: [rpc_dart_websocket, rpc_dart_http2, rpc_dart_http, rpc_dart_isolate, rpc_dart]
lens: RPC-19
bench: P-17 — new
budget: probes 2/3, canaries 2/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record. Approved 7 of 7; Q2 is the one this round nearly failed, see Canary
commit: yes
---

# Round 238 — the recovery API works more than once

## Target

RPC-19, never applied: one boolean carrying both "the caller closed us"
(terminal) and "the connection is gone" (recoverable), so every reader
interprets it in whichever sense suits that call site.

## Hypothesis

There is a third instance. The two known ones — the http2 caller (63aa8e93) and
the websocket caller (3bfa7715) — were both found by driving the recovery API
the way an application does, and nothing else in the tree had been driven that
way.

## Before

**The static half first.** Every lifecycle flag in the lens's paths, with its
writers:

```
  http/1.1 caller  _isClosed      one writer, close()      no recovery path
  http/1.1 responder, http2 responder                      server side, none
  isolate, isolate web, wasm x2   one writer each          no in-place reconnect
  websocket channel _closed       close + closeForProtocolError, both terminal
  servers _isRunning              start/stop, RPC-21's shape, clean at C-06
  http2 caller     _isClosed + _disconnected               split, fixed
  websocket caller _closed + _disconnected                 split, fixed
```

Every single-flag class either has no recovery path — so the shape cannot arise
— or already carries the split. **A flag conflates two meanings only where two
meanings exist.**

**One hypothesis died to rule one rather than to a probe.**
`RpcClientConnection._connectWithBackoff` sets a single-flight
`_connectingGuard` and returns early while it is incomplete, so a guard left
uncompleted on any exit path would make `connect()` and `forceReconnect()`
permanent no-ops — exactly "works exactly once". Reading every exit: max
attempts (503), stopped-after-factory (569), missing capability (606), success
(614), shouldReconnect false (627), and the loop's own exit (634). All six
complete it.

**The behavioural half, which is what the lens actually asks.** The websocket
suite drives ONE failed reconnect then a successful one; the http2 instance was
found by retrying until the peer came back. So: four failed attempts into a dead
peer, then recovery, then a real call — twice.

```
  cycle 1   recoverable=true   recovered=true   callWorks=true   serverUp=true
  cycle 2   recoverable=true   recovered=true   callWorks=true   serverUp=true
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/retry_until_the_peer_returns.dart`
(bench `../probes/P-17-retry-until-the-peer-returns.md`).

## Mechanism

Nothing is wrong. The shape is absent because the two places that could hold it
already hold the vocabulary — `_closed` written only by `close()`,
`_disconnected` for "no connection, recovery expected" — and every other
lifecycle flag in these packages belongs to an object with no recovery to
confuse.

## After

n/a — nothing changed. `git diff` empty against HEAD.

## Canary

**Q2 is where this round nearly went wrong, twice.**

The rig lied first. A fresh `RpcCallerEndpoint` per call, closed in a `finally` —
and `RpcEndpointBase.close()` closes the TRANSPORT it was given, so the probe
shut its own client down at the end of cycle 1. Cycle 2 read
`recovered=false, health: "Transport closed"`, which is precisely what the
defect would look like. It was separated from a real finding by checking
`serverUp` with a plain socket and by printing the health message — not by
reasoning about the result.

Then the ablation lied. Removing the `_disconnected` branch from `health()`
changed **nothing**, because this bench reads what `reconnect()` RETURNS, and
that has its own `supported: true`. Ablating the flag the probe actually samples
— `_closed = true` in `_reconnectOnce`'s catch, the pre-63aa8e93 shape — turned
every column false in both cycles.

```
  ablated   cycle 1  recoverable=false  recovered=false  callWorks=false
            cycle 2  recoverable=false  recovered=false  callWorks=false
```

That is what makes CLEAN mean something here rather than "the probe saw
nothing".

## Gate

No code changed; the gate proper is the one HEAD passed at round 237. `git diff`
against `packages/` is empty, which is the claim being made.

## Not fixed

**Only the websocket caller was driven behaviourally.** http2's equivalent is
covered by `reconnect_failure_is_recoverable_test.dart` and
`reconnect_close_race_test.dart`, and `RpcClientConnection`'s resume path by
`connect() resumes after disconnect()` and `forceReconnect() resumes after
disconnect()` — but those are existing tests read, not a battery run. The bench
is written to take another transport by swapping the rig.

**The probe is not a test.** Two cycles against a real server that binds and
rebinds a port is slow and port-sensitive, and the severity bar forbids coverage
for its own sake when the result is clean. It is registered as a bench instead,
so the next round on these paths starts from it.

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` — `applied: [238]`,
status `swept here (round 238, 9cbd2d47)`.
Bench `../probes/P-17-retry-until-the-peer-returns.md` — new, validated by an
ablation that took two attempts to aim correctly.
Round `234` — the peer-started drop, the other half of driving reconnect the way
an application does.
