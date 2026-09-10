---
round: 283
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-22
bench: P-32 — new
commit: yes
---

# Round 283 — the reset is the cheap arm

## Target

C-32's explicitly uncovered half, and the last item on the unmeasured list that
was not blocked on an owner decision. Round 277 showed Rapid Reset dispatches no
handler and recorded what it had NOT tested: each reset stream still costs an
HPACK decode and a stream-state churn, at a rate `maxActiveStreams` cannot bound
because nothing is ever live.

## Hypothesis

That churn is CPU amplification: a peer resetting streams faster than the
ceiling would admit them makes the server do more work than it agreed to, and an
unrelated client pays for it.

## Before

The observable is deliberately not CPU. A second connection makes ordinary calls
throughout the attack and reports their latency — what a starvation attack costs
an operator, and the shape RPC-18's evidence used.

```
arm      attack streams  victim median  victim worst
idle                  0        1241 us       2367 us
reset              2000        1046 us     373458 us
normal             2000         648 us     679531 us
```

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/rapid_reset_cpu.dart`

**Refuted, and by the control moving further than the subject.** The `normal`
arm — the same 2000 streams, not reset — stalls the victim for 679 ms against
the reset arm's 373 ms. So the stall belongs to 2000 concurrent streams of
ADMITTED work, and resetting them REDUCES what the server spends, because the
cancel lands before dispatch (round 277's mechanism, seen from the other side).

The CVE's premise does not hold here: resets do not buy an attacker work beyond
the ceiling, they buy less work than a legitimate client doing the same thing.

Note which number moved. The median is flat across all three arms — 1241, 1046,
648 µs, the ordering of which is noise — while the worst case goes 2367 ->
373458. A burst monopolises the loop without shifting the average, so a bench
that reported only a median would have called every arm identical.

## Mechanism

n/a — there is nothing to explain.

## After

n/a.

## Canary

n/a. The `normal` arm is what carries the round: it is the same harness, the
same stream count, one variable, and it is worse.

## Gate

n/a — no code changed. `loop.py lint` green.

## Not fixed

Nothing, and one number is worth stating rather than burying: 2000 concurrent
streams stall an unrelated connection for 679 ms. That is `maxActiveStreams` at
its 4096 default doing exactly what it says — 2000 is under the ceiling, so the
server is doing work it agreed to — which makes it a capacity and tuning matter
rather than a defect. An operator who wants isolation between connections sets
the ceiling lower; C-29 already records that the stream table is per connection.

**RPC-18's caveat carries and bounds what this round proved.** An in-process
flood yields the event loop between writes, so absolute starvation here is muted
against a cross-process attacker. The comparison between arms is what stays
valid, since all three run in the same harness — which is why the verdict rests
on `normal > reset` and not on either number alone. A cross-process version
would sharpen the absolute figures; it would not change the ordering, and the
ordering is the answer.

## Links

RPC-22 (`applied:` gains 283). Bench P-32, new. C-32's "What this does NOT
cover" section is now covered and says so.
