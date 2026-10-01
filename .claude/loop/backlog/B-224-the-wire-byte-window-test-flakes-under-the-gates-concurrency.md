---
status: open
round: 588 (three of five members fixed; two remain)
commit: 878c443b
paths: [packages/core/rpc_dart/test/transports/oversized_chunk_not_copied_test.dart, packages/core/rpc_dart/test/endpoint/the_drain_is_signalled_not_polled_test.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/b224_how_much_margin_the_park_has.dart
reason: "bench — the CAUSE is settled (the gate runs ~16 suites on 8 cores) and three members are fixed. The two left measure a shared resource no wait can isolate: the PROCESS's RSS, and a 35 ms latency ceiling. Both need a serial lane, which is a change to the gate's shape"
---

# B-224 — the suite's timing assertions break when the gate oversubscribes its cores

Filed by round 587 as a load flake on one test. Round 588 refuted that explanation
and found the family.

## The cause, settled in round 588

```
Platform.numberOfProcessors        8
dart test default concurrency     ~4
melos exec --concurrency            4
gate effective                    ~16 concurrent suites on 8 cores
```

2x oversubscribed, which is why the gate fails intermittently rather than always.
Reproducible on demand one step above it:

```
melos exec --scope=rpc_dart -- fvm dart test --concurrency=16   green
                                             --concurrency=24   RED, twice, different members
                                             --concurrency=32   RED
```

**It is NOT CPU load from elsewhere.** 14 busy isolates in another process, load
average 84.76 — eight times the 11.37 round 587 blamed — and the arm reads clean.
`P-208`.

## The family

Each member measures a SHARED resource as if the test owned it.

```
FIXED    the_window_counts_wire_bytes_test   a fixed settle must cover ~66 timer turns
FIXED    response_sink_stops_at_the_ending   200 ms must cover >5 turns at a 5 ms pace
FIXED    audit_frame_reassembly_linear       a wall-clock RATIO between two batches
OPEN     oversized_chunk_not_copied          a bound on the PROCESS's RSS
OPEN     the_drain_is_signalled_not_polled   a 35 ms latency ceiling
```

How the three were fixed, since the same remedies apply to anything new:

- **A settle becomes a condition wait** with a ceiling. The ceiling is not the wait;
  when the guarded mechanism is broken the condition never holds, the ceiling
  expires, and the arm's own `expect` reports it. Sample the state AT the condition,
  not wherever the clock ran out.
- **A ratio is INTERLEAVED.** Minima over N reps suppress jitter within a batch and
  do nothing about contention rising between two batches. Alternating N and 2N put
  both in one window: `concurrency 24` read `15698 / 31040, ratio 1.98` against a
  quiet `10091 / 19904, ratio 1.97` — both halves inflated 1.56x and the ratio held,
  with the 3.0 threshold untouched.

## What is left, and why patience does not fix it

```
oversized_chunk_not_copied     Expected a value less than <16777216>, Actual <31653888>   at 32
the_drain_is_signalled_not_polled   Expected a value less than <35>, Actual <92>          at 32
```

With 32 isolates in one process, `currentRss` is not this test's number and no amount
of waiting changes it; a latency CEILING is a statement about scheduling that
contention falsifies by definition. Neither can be converted into a condition wait —
you cannot wait for the absence of an event.

Both appear only ABOVE the gate's effective 16, so neither is what the gate reported.

## What a round owes this

**A serial lane.** `dart test` takes `--tags`, so the shape is: tag these arms,
exclude the tag from the ordinary run, and add one more invocation that runs the tag
with `--concurrency=1`. That touches the `test`/`test:unit` scripts, which is the
gate's shape and the owner's call — the memory note already records that raising
this concurrency was measured and rejected, so the gate's own numbers are not to be
changed casually.

**Or make each self-relative instead of absolute**: an RSS DELTA across a control
measured in the same run, and a latency compared against an uncontended baseline
taken beside it. More work per arm, no change to the gate.

**And a frequency at the gate's own 16**, which nothing has: two reds and a green in
587, two greens in 588, is four data points. The reproduction was done at 24 because
it is frequent there, and that is a different question from the rate the gate sees.

## Owner decision

—
