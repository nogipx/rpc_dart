---
round: 849
verdict: FIXED
packages: [rpc_dart]
lens: RPC-09
bench: P-318 — new
commit: yes
severity: S2 — "a limit that is off but still bounds"
release: none
---

# Round 849 — a clock jump does not stretch the reconnect wait

## Target

Network-audit method §7: "a clock that jumps (deadlines must use a
monotonic clock where the runtime offers one)". The journal had measured it
for the drains (B-123, round 514) and not for a call's deadline. rpc_dart
keeps a deadline as a wall-clock instant (`clock()`, `DateTime.now` by
default) and arms monotonic timers from it; a path that re-reads the clock
after the timer fires can disagree with them. RPC-09, raised in the curate
pass for re-measurement. Before it, read and not taken: the isolate
transport's inbound checks (type, negative ids, payload type, all caught
into the stream since round 698).

## Hypothesis

A call ends at its deadline whatever its context's wall clock does. Fails
if a jump stretches or shortens a wait the deadline bounds.

## Before

```
shape (P-318)          jump      ended after   with
unary/server/client/bidi  -3600 s   1009-1020 ms  DEADLINE_EXCEEDED   (as with no jump)
server                 +3600 s   1012 ms       DEADLINE_EXCEEDED
retry reconnect wait   0 s       1003 ms       DEADLINE_EXCEEDED
retry reconnect wait   -3600 s   5112 ms       UNAVAILABLE
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/r849_clock_jump.dart` and
`r849_retry_clock_jump.dart` beside it.

## Mechanism

The retry interceptor's reconnect wait re-reads `context.remainingTime` when
its timer fires and re-arms while any time is left. That was added in commit
0a590c56 (this session, unpushed) to catch a Timer firing a sliver before
the context's clock reaches the deadline. A clock that jumped back reads an
hour left, so the wait re-armed until the reconnect's own 5 s limit ended
it.

## Fix

The wait re-arms only for a rest under 50 ms, the sliver it was written
for; a larger rest ends it on time. The call then reads time left on its
jumped clock and fails UNAVAILABLE at about 1 s.

## After

```
retry reconnect wait   -3600 s   1000 ms   UNAVAILABLE (the context still reads time left)
```

## Canary

`packages/core/rpc_dart/test/resilience/a_reconnect_waits_no_longer_than_the_call_test.dart`:

- Re-arm on any rest: "a clock that jumps back does not extend the wait"
  failed with `held past the deadline: 5106 ms`; the other five green.
- Never re-arm: "the wait ends after the deadline, not just before it"
  failed at call 20 with `Actual: Duration:<0:00:00.000125>`; the clock-jump
  test green.

The file passes three runs in a row and on node.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart +2215 ~1, http +259, http2 +318, websocket +331); `format:check`
SUCCESS; `license:check` compliant.

## Siblings

—

## Not fixed

- The responder's deadline was not jumped: its context reads `DateTime.now`
  and this bench cannot move it.
- The outcome under a jump is UNAVAILABLE, not DEADLINE_EXCEEDED: the
  context's own clock says time is left. Which one a jumped clock should give
  is a question; what the wait must not do is overrun.

## Links

Lens `../lenses/RPC-09-deadline-below-write.md`. Bench
`../probes/P-318-a-wall-clock-jump-during-a-call.md`. Negative
`../checked/C-84-a-call-deadline-holds-through-a-clock-jump.md`.
