---
round: 531
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-19
bench: P-164 — new
commit: yes
---

# Round 531 — the restart that ran inside the shutdown

## Target

B-135, next in rank order: `start()` during a draining `stop()`.

Lens RPC-19 — one flag with two lifecycle meanings. `_isRunning` is both "accept connections"
and "a shutdown is not in progress", and those come apart for the whole length of a stop.

## Hypothesis

`start()` sets `_isRunning = true` at once, the still-running stop then closes connections
accepted after the restart, and `_endpoints.clear()` drops ones added during the close loop
without closing them.

## Before

```
  fresh connection arrives   server running   the fresh one   endpoints held
  drain                      true             torn down       0
  close                      true             never           0
  after                      true             never           1
  nothing                    true             never           1
```

Bench `../probes/P-164-what-happens-to-a-connection-accepted-mid-shutdown.md`.

**Both halves CONFIRMED, one per phase.** A connection accepted during the drain is torn down
by the shutdown the caller had already superseded, while `isRunning` reads true. One accepted
during the close loop is worse: `_endpoints.clear()` drops it without closing it, so no later
`stop()` or `dispose()` knows it exists — the peer holds a working socket this server has
forgotten. That is the state `_handleConnection`'s own comment calls out as the one worth
refusing a peer to avoid.

The controls are `after` (the ordinary restart) and `nothing` (never stopped). Without them
`endpoints held: 0` is equally consistent with a rig that never delivered a connection.

## Mechanism

`_isRunning = false` is set at the top of `stop()` and every piece of its work happens after
it. A `start()` in that window sees `_connectionsSub != null`, sets the flag back, and returns
— while the stop carries on from where it was.

## After

Every row reads `never / 1`. `stop()` publishes the attempt in `_stopping` before its first
await, and `start()` awaits it: the caller asked for a stop and then a start, and gets them in
that order. Peers arriving in between are refused by `_handleConnection`, which ANSWERS them —
being accepted and then destroyed is what that replaces.

## Canary

The `await _stopping` removed from `start()`: the drain witness fails
`Expected: 'never' / Actual: 'torn down'` and the close witness fails `Expected: <1> /
Actual: <0>` with its own reason. Both controls and the guard pass in that state.

The guard is the one that bounds the fix: mid-shutdown with NO restart asked for, a peer must
still be refused — answered with a close and a reason, never accepted. A change that had made
`_handleConnection` accept during a stop would have passed both witnesses.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. The websocket package:
225 passed.

## Not fixed

**A probe arm was silently wrong first, and that is the round's method finding.** The drain arm
had no in-flight call, so `_drain` returned on its first poll and the arm became a second copy
of the close arm — two identical rows for two different questions, which read as a consistent
result rather than as a broken rig. Only building the real call separated them, and only then
did the lead's FIRST claim get confirmed at all.

**`start()` can now block for the whole drain budget.** A supervisor that fires
`stop(drainTimeout: 30s)` and `start()` back to back waits 30 s for the start. That is the
requested order and the witness asserts the serialisation, but it is a behaviour change on a
published package and wants a CHANGELOG line.

**Overlapping `stop()` calls are not single-flighted.** `_stopping` exists so `start()` can
wait; a second `stop()` with a different budget still returns immediately because `_isRunning`
is already false, which means its budget is ignored. Not measured, not fixed — filed nowhere,
because deciding what a second stop SHOULD mean is a design question.

**No real sockets.** Every channel is in-memory, so what the peer observes at the TCP level in
each window is untested.

## Links

Lens RPC-19. Bench P-164 (new). Lead B-135 closed. Round 530 fixed the close loop this round
races with; `_handleConnection`'s refusal is what makes the fix safe rather than merely
ordered.
