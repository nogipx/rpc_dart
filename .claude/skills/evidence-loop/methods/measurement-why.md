# What paid for each measurement item

> [Methods](METHODS.md) · the operative list is
> [measurement.md](measurement.md), printed by `loop.py brief` · what a bench
> file looks like: [specs/probe.md](../specs/probe.md) · the domain items are in
> [items/](../items/ITEMS.md)

Open a section when its item is the one biting. The numbers are the size of the
trap, not a reference to a particular case.

## Where probes live

`config.md`, section "Probes". A probe lives inside the package so its imports
resolve, stays out of analysis and out of git, and is overwritten rather than
deleted. **Its file name goes in the round record**, or the measurement is
reproducible for nobody else.

## The two directions a wrong metric lies in

**It can INVENT a defect.** A flood of garbage identifiers looked like
per-stream flow control switched off: 88 KiB clean against 16 364 KiB under the
flood, a 186x gap. The bench had given both ends ONE policy object, so the flood
filled the sender's own credit and the unbounded send was self-harm.

> **When the attacker and the victim share a config, there is no way to tell
> whose ceiling bounded the result.** Give them separate ones.

**It can INVERT the result.** A sender-side counter gave 156 MiB "with the fix"
against 71 MiB without it, and the working change was reverted. A byte-level
relay showed the truth: 4.4 MiB against 13.8 MiB.

> **Before believing a before/after pair, ask which SIDE the number was taken
> on.** If a fix supposedly made a metric much worse, suspect the metric first.

## Measure what the library does, not what the bench does

Substitutions that have bitten: counting the handler's output instead of the
bytes actually sent; taking RSS where a direct counter was available; writing
into your own buffering controller, which is unbounded and accepts anything. To
measure how much the library PULLS, feed it a lazy generator.

## RSS growth is not evidence of a leak

1. **Linearity.** Compute "bytes per unit of attack" at 3+ scales. Retention
   keeps that number constant; churn makes it fall. A flood of service frames
   gave 207 -> 121 -> 74 bytes per frame while the totals grew 41 -> 97 -> 177
   MiB: heap headroom, not a leak.
2. **A control that removes the suspected mechanism.** Making the attacker DRAIN
   the socket barely moved the number (96.7 -> 82.2 MiB), refuting the
   reply-queue theory outright.

**Read the CURVE, not just the direction.** A fall to a PLATEAU is retention
(31187 -> 14090 -> 8446 -> 8113 bytes per frame); a fall all the way down is
churn (744 -> 497).

**A short window turns "slow" into a false BOUNDED.** A load at 6.4 MiB by the
4th second looked bounded; the per-second delta was merely decaying (1250/s ->
400/s) and by the 12th second it was 24.2 MiB and still growing. Watch the delta
per interval, and run until it plateaus or fails to.

High RSS at a high frame rate is normal and is a matter for rate limiting at the
deployment level. Do not ship a defence on rising RSS alone.

## Controls

- **The best control is often a case you have already run.** Two modes pushing
  the same volume through the same socket and differing only in the stream id
  cancel out the client-side cost. Look for the variant that holds the bench
  constant before building a byte-level relay.
- **If the control shows the same symptom as the case under test, the bench is
  wrong, not the library.** A "confirmed" leak evaporated this way: the handler
  ran 10 s while the probe observed for 7, so both the aborted case and the
  clean control reported "still running".
- **Calibrate the control against the observation window** before believing
  either side.
- **Ablation**: switch off one part of the fix at a time, confirming each is
  load-bearing.

## Performance rounds

- **Baseline first, and write it down.** A speed-up with no "before" is not a
  claim.
- **An optimisation needs a canary too**: revert it and re-measure. If removing
  it does not move the number, it was doing nothing.
- **Single measurements on a developer machine are not evidence.** The same
  binary gave 67k -> 116k msg/s between runs. Take medians across RUNS, and
  watch the machine's load: a full suite drives the 15-minute average past 16,
  and wall-clock lies there.
- **Measure what the user pays for**: end-to-end latency and sustained
  throughput on a real transport. Go to a microbenchmark only after a profile or
  an end-to-end number has named a suspect.
- **Keep an in-memory pair as the CONTROL**: the same stack with no socket. The
  gap is the transport's cost.
- **Never move a bound for speed.** Trading safety for throughput is the owner's
  decision, not a round's.
- **Profile before the third guess.**

## Forensics

**A bisect tells you who takes part, not who is at fault.** Switching off the
error delivery "fixed" a crash whose real cause was a listener that did not
handle it.

The rest depends on the language and runtime: `items/measure-dart-why.md` and
so on.
