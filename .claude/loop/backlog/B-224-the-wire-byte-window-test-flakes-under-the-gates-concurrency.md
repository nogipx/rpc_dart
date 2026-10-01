---
status: open
round: 587
commit: 08d2f17c
paths: [packages/core/rpc_dart/test/transports/the_window_counts_wire_bytes_test.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: none — observed in the round-587 gate, not yet instrumented
reason: "bench — a gate that fails intermittently trains the reader to re-run rather than to look. Seen twice in one round at load 11.37, green alone and green on the third gate run; the ASSERTION is a park, which is what makes it timing-shaped"
---

# B-224 — `the_window_counts_wire_bytes_test` flakes under the gate's concurrency

Observed in round 587's gate, whose change was in `rpc_dart_http` and cannot reach
core's flow control.

```
WITNESS a half-closed request does not end the response's window
  Expected: <1>
    Actual: <0>
  the sender must be parked on the window, not running free
```

Two `melos run test:unit --no-select` runs in a row, then:

```
the file alone                      7 of 7 pass
the third full gate run             rpc_dart +1876 ~1, SUCCESS
load average at the time            11.37
```

`config.md`'s bar for a timing measurement is a quiet machine; B-215 states it as
`uptime` under 3. This was taken at 11.37, driven by the round's own 256 MiB probe
runs.

## Why it is worth a lead rather than a shrug

The assertion is that a sender is PARKED — a state that exists only while something
has not happened yet. Under `--concurrency 4` on a loaded machine the producer can
be descheduled long enough for the sampled count to read `0` either because the
window is working and the send has not been attempted yet, or because the window is
not working and the send already drained. **Those two are the same reading**, which
is the same defect shape as `L-15`: an arm that cannot distinguish its own success
from its own failure.

Rounds 582-586 ran the same gate green five times, so the frequency is low — and a
low-frequency red on an assertion that cannot self-distinguish is the worst kind,
because the next reader re-runs and moves on. This round did exactly that.

## What a round owes this

**A frequency, not an anecdote** — N runs under the gate's concurrency on a quiet
machine (`uptime` stated), and N on a loaded one, so "load" is shown to be the
variable rather than assumed.

**Then make the arm self-asserting**, which is the fix whichever way the frequency
comes out: sample something that is only true when the producer has ATTEMPTED the
send and been refused, instead of counting what has arrived. `P-64`'s hop check is
the pattern — assert the setup inside the arm.

**Do not simply raise a delay.** That hides the ambiguity rather than removing it,
and the next loaded machine is slower than whatever number is chosen.

## Owner decision

—
