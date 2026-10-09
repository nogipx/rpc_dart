---
file: packages/core/rpc_dart/.dart_tool/probe/b224_how_much_margin_the_park_has.dart
round: 588
commit: 878c443b
paths: [packages/core/rpc_dart/test/transports/the_window_counts_wire_bytes_test.dart, packages/core/rpc_dart/test/streams/response_sink_stops_at_the_ending_test.dart, packages/core/rpc_dart/test/audit/audit_frame_reassembly_linear_test.dart]
status: valid
---

# P-208 — how much margin a timing assertion has

## Why it exists

`the_window_counts_wire_bytes_test` sleeps 250 ms and then requires the sender to
be parked. Round 587 called the resulting gate red a load flake and filed it. That
was a guess: nothing had measured how long the park actually needs, so "250 ms is
plenty" was an assumption, not a reading.

The probe asks the only question that settles it — **what is the margin?**

## The harness

The test's own first arm, with the settle as a parameter and `produced` reported
beside the state the test asserts on. The test throws that counter away, and it is
the one number that tells the two failure branches apart: `waiters == 0` with a
small `produced` means the producer never got there, and `waiters == 0` with a large
one means it got there and was released.

## The numbers (round 588)

Quiet machine:

```
settle       0 us (actual   39309)   produced     1   advertised 1  sendCredit 1  waiters 0
settle     100 us (actual    1180)   produced     1   advertised 1  sendCredit 1  waiters 0
settle    1000 us (actual    1283)   produced     5   advertised 1  sendCredit 1  waiters 0
settle    5000 us (actual    5186)   produced    61   advertised 1  sendCredit 1  waiters 0
settle   25000 us (actual   26933)   produced    66   advertised 1  sendCredit 1  waiters 1
settle  250000 us (actual  254551)   produced    66   advertised 1  sendCredit 1  waiters 1
```

**The park arrives at 66 produced and needs between 5 and 25 ms**, because the
handler awaits a `Duration.zero` TIMER per message and each one costs an event-loop
turn. So the margin is 10x to 50x, not the 250x the settle looks like.

## Control

**Under external CPU load the reading does not move**: with 14 busy isolates in
another process and a load average of 84.76, the 250 ms arm still read `waiters 1`.

That is the control that refuted round 587's explanation. Raw CPU starvation of
another process is not what breaks these arms; `dart test`'s own suite concurrency
is, and the two are not the same thing — see the round.

## Measures

Messages produced before the sender parks, and the wall-clock needed to get there,
against the settle the assertion allows.

## What it establishes, and what it does not

Establishes the margin, which is what makes the failure explicable rather than
mysterious, and establishes that external CPU load is not the variable.

Does NOT itself reproduce the gate failure — `melos exec --scope=rpc_dart -- fvm
dart test --concurrency=24` does that, and is the instrument the round used for
reproduction. This probe explains why that works.

Does NOT measure the other members of the family (a wall-clock ratio, a process RSS
bound, a latency ceiling); it measures the one the gate reported.

## Reading

rpc_dart — **asks the one question that converts "flaky" into a quantity: what
is the MARGIN?** A 250 ms settle requiring a parked sender, run at six settles
with the counter the test throws away: the park arrives at `produced 66` and
needs **5-25 ms**, so 10-50x and not the 250x the number looks like. **Its
control is what refuted the previous round's explanation** — 14 busy isolates
in another process at load `84.76`, eight times the figure blamed, and the arm
still reads `waiters 1`. So external CPU pressure is not the variable; `dart
test`'s own suite concurrency is, and `--concurrency=24` is the instrument
that reproduces. Reports `produced` beside `waiters` deliberately: `waiters 0`
means either "never got there" or "got there and was released", and only the
counter separates them
