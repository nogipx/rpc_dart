---
round: 588
verdict: FIXED
packages: [rpc_dart]
lens: RPC-15
bench: P-208 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: none
---

# Round 588 — the gate oversubscribes its own cores

## Target

`B-224`, filed by round 587 one round earlier — and the thing being re-measured is
that round's own explanation. The owner asked why the tests had started failing,
which is a question 587 answered with a guess.

Lens RPC-15: re-measure the loop's own record. 587 wrote *"load average 11.37
against the quiet-machine bar"* and called it a flake. Nothing had measured what the
assertion needs, so "250 ms is plenty" was an assumption.

## Hypothesis

587's: CPU load. Tested first, and REFUTED.

## Before

```
the gate, runs 1 and 2    the_window_counts_wire_bytes_test:192  waiters Expected <1> Actual <0>
the gate, run 3           green
the file alone            7 of 7 pass
```

**587's explanation does not survive its own control.** With 14 busy isolates in
another process and a load average of **84.76** — eight times the 11.37 that was
blamed — the arm still reads `waiters 1`:

```
load 84.76, settle 250 ms   produced 66   waiters 1
```

So raw CPU starvation is not the variable.

## Mechanism

Two readings together name it.

**First, the margin.** `P-208` runs the arm at six settles and reports the counter
the test throws away:

```
settle    1000 us   produced     5   waiters 0
settle    5000 us   produced    61   waiters 0
settle   25000 us   produced    66   waiters 1
settle  250000 us   produced    66   waiters 1
```

The park arrives at 66 produced and needs **5 to 25 ms**, because the handler awaits
a `Duration.zero` TIMER per message and each one costs an event-loop turn. The
margin is 10-50x, not the 250x the settle looks like.

**Second, the actual variable.** It is `dart test`'s own suite concurrency, not CPU
pressure from elsewhere:

```
melos exec --scope=rpc_dart -- fvm dart test --concurrency=16   green
                                             --concurrency=24   RED, twice, different members
                                             --concurrency=32   RED
```

And the number that ties it to the gate:

```
Platform.numberOfProcessors        8
dart test default concurrency     ~4
melos exec --concurrency            4
gate effective                    ~16 concurrent suites on 8 cores
```

**The gate oversubscribes 2x, which sits exactly at the threshold** — which is why
it fails intermittently rather than always: sometimes the heavy suites land
together, sometimes they do not.

## The defect is a family, not a test

Cranking the concurrency produced four members, each measuring a SHARED resource as
if the test owned it:

```
the_window_counts_wire_bytes_test     a fixed settle must cover ~66 timer turns
response_sink_stops_at_the_ending     200 ms must cover >5 turns at a 5 ms pace
audit_frame_reassembly_linear         a wall-clock RATIO between two batches
oversized_chunk_not_copied            a bound on the PROCESS's RSS
the_drain_is_signalled_not_polled     a latency ceiling of 35 ms
```

## After

Three fixed — the two the gate reported, and the ratio that failed twice at 24.

**The two settles become condition waits.** `_until(predicate, ceiling: 10s)`: the
ceiling is not the wait, and when the guarded mechanism is broken the condition
never holds, the ceiling expires and the arm's own `expect` reports it with its own
reason. The window arm now also samples `first` AT the park rather than wherever the
clock ran out, which it had no right to call the window's number before.

**The ratio is INTERLEAVED.** It already took minima over 5 reps, and minima were
not enough: they suppress jitter WITHIN a batch and do nothing about contention
rising BETWEEN two batches, which inflates whichever size was measured second.
Measuring N and 2N alternately puts both in the same window, so a drift moves
numerator and denominator together:

```
quiet            dribble(N)=10091us  dribble(2N)=19904us  ratio 1.97
concurrency 24   dribble(N)=15698us  dribble(2N)=31040us  ratio 1.98
```

Both halves inflated by 1.56x and the ratio did not move. That is the fix working,
not the threshold being loosened — it is unchanged at 3.0.

## Canary

```
the window ablated on the first arm (`window: null`)
  WITNESS a half-closed request does not end the response's window
    Expected: <1>
      Actual: <0>
```

So the arm is not vacuous: it still fails when the thing it guards is off.

**One thing is a reading rather than a measurement, and it is worth saying.** That
`_until` cannot hang is read off three lines (`while (!done() && before(deadline))`),
not witnessed — two attempts to drive the ceiling path took other branches: `window:
null` routes to the plain-settle arm, and a 512 MiB window parks anyway at ~5 s for a
reason this round did not chase.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   twice, rpc_dart +1876 ~1 both times
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2229 / 2229, REUSE compliant

melos exec --scope=rpc_dart -- fvm dart test --concurrency=24   green, twice
```

## Not fixed

**Two members remain, and both need isolation rather than patience.**
`oversized_chunk_not_copied_test` bounds the PROCESS's RSS (`Expected less than
<16777216>, Actual <31653888>` at 32) — with 32 isolates in one process that number
is not this test's, and no amount of waiting changes it.
`the_drain_is_signalled_not_polled_test` asserts a 35 ms latency ceiling and read 92
at 32. Both appear only ABOVE the gate's effective 16, so they are not what the gate
reported; both stay on `B-224`. The remedy for either is a serial lane, which is a
change to the gate's shape and the owner's call.

**The gate's own oversubscription is left alone.** `melos exec --concurrency 4` times
`dart test`'s default 4 is 16 suites on 8 cores, and lowering either would slow every
run to fix a symptom — the memory note already records that raising this
concurrency was measured and rejected. The assertions are what was wrong.

**No frequency was established at the gate's own 16.** Two reds then a green in 587,
then two greens here, is four data points; the reproduction was done at 24 instead,
where it is frequent. What this round shows is the mechanism and that the fixed arms
survive 1.5x the gate's load, not a rate.

## Links

Lead `../backlog/B-224-the-wire-byte-window-test-flakes-under-the-gates-concurrency.md` — the family and the two remaining members.
Bench `../probes/P-208-how-much-margin-a-timing-assertion-has.md` — new.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [588]`.
Round `587` — whose `## Gate` section carries the explanation this round refutes.
Lesson `../lessons/L-19-a-flake-is-a-hypothesis.md` — new.
