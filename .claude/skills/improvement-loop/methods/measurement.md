# Measurement discipline

> [Methods](METHODS.md) · at the **Bench** step · the domain items that extend
> this checklist are in [packs/](../packs/PACKS.md) · what a bench file looks
> like: [specs/probe.md](../specs/probe.md)

**Contents.** The checklist is the operative part; each section below it is the
story one item cost, and is worth opening when that item is the one biting.

- Checklist — before building a probe, and whenever a number surprises you
- Where probes live
- The two directions a wrong metric lies in
- Measure what the library does, not what the bench does
- RSS growth is not evidence of a leak
- Controls
- Performance rounds
- Forensics

## Checklist — before building a probe, and whenever a number surprises you

1. `probes/` first: a valid bench along the same paths (named by `loop.py next`)
   is reused, and the round starts by repeating its control. Build a new one
   only if there is no valid bench, or its control has stopped differing from
   the case under test (then the bench gets status `broken`).
2. A probe measures one number and lives where `config.md` says ("Probes"); its
   name goes into the round record, or the measurement is not reproducible.
3. A probe has a control: the same bench with the suspected mechanism removed.
   Without a control the number means nothing. Once a control has shown the
   bench sees the defect, the probe has become a bench: record it as `P-N` per
   `specs/probe.md`.
4. If the control shows the same symptom as the case under test, the bench is
   wrong, not the library. Fix the bench, do not ship a fix.
5. Ask which SIDE of the system the number was taken on. If a fix appears to
   have made a metric much worse, suspect the metric first.
6. Measure what the library does, not what the bench does: bytes actually sent,
   a direct counter, a lazy generator on the input.
7. RSS growth is not a leak. Compute "bytes per unit" at three scales and read
   the curve: a plateau is retention, a fall all the way down is churn. Run to a
   plateau or to its absence, and watch the delta per interval.
8. Zero is suspicious: check whether the mechanism could emit anything at all.
9. Performance: the baseline is recorded; medians across runs, not within one; a
   profile before the third guess; never move a bound for speed.
10. Count your own rebuilds of the bench. Past `probes: N` from the config with
    no valid number the verdict is INCONCLUSIVE, and a "bench" lead lists what
    was tried. Not CLEAN. Whatever the rebuild cost becomes a lesson `L-N` with
    its price.

`loop.py next` adds the enabled packs' items (`config.md`, the `packs:` line) to
this list; read them together. Below is what paid for each item. The numbers
beside them are the size of the trap, not a reference to a particular case: a
rule with no size is easy to talk away, while a size carries anywhere.

## Where probes live

The path and the convention are in `config.md`, section "Probes". The general
rule: a probe lives inside the package so its imports resolve, stays out of
analysis and out of git, and is overwritten rather than deleted. **The probe's
file name must be given in the round record**, or the measurement is
reproducible for nobody else.

## The two directions a wrong metric lies in

**It can INVENT a defect and make you ship a fix for nothing.** A flood of
garbage identifiers looked like per-stream flow control being switched off:
88 KiB on a clean run against 16 364 KiB under the flood, **a 186x gap** — the
exact shape of a real hole; the fix and its explanatory comment were already
written. The bench had given both ends ONE policy object, so the flood filled
the SENDER's own credit, and the unbounded send was self-harm.

> **When the attacker and the victim share a config, there is no way to tell
> whose ceiling bounded the result.** Give them separate ones. After the split
> the gap vanished, and a canary showed the old code bounds it exactly the same.

**It can INVERT the result and make you revert a correct fix.** A sender-side
counter gave 156 MiB "with the fix" against 71 MiB without it, and the working
change was reverted. A byte-level relay showed the truth: 4.4 MiB against
13.8 MiB.

> **Before believing a before/after pair, ask which SIDE the number was taken
> on.** If a fix supposedly made a metric much worse, suspect the metric first.

## Measure what the library does, not what the bench does

Substitutions that have bitten: counting the handler's output instead of the
bytes actually sent; taking RSS where a direct counter was available (GC drowns
it); writing into your own buffering controller, which is unbounded and accepts
anything. To measure how much the library PULLS, feed it a lazy generator
directly.

## RSS growth is not evidence of a leak

Two cheap checks separate a real leak from a GC high-water mark.

1. **Linearity.** Compute "bytes per unit of attack" at 3+ scales. Retention
   keeps that number CONSTANT; allocation churn makes it fall. A flood of
   service frames gave 207 -> 121 -> 74 bytes per frame at three scales: the
   growing totals (41 -> 97 -> 177 MiB) looked alarming until the per-unit
   figure showed it was heap headroom.
2. **A control that removes the suspected mechanism.** Making the attacker DRAIN
   the socket barely moved the number (96.7 -> 82.2 MiB), which directly
   refuted the reply-frame-queue theory. Without the control we would have
   shipped a defence against a mechanism that had nothing to do with it.

**Read the CURVE of the per-unit value, not just its direction.** A fall
followed by a PLATEAU is retention (31187 -> 14090 -> 8446 -> 8113 bytes per
frame, asymptotic at about 2x the payload); a fall all the way down is churn
(744 -> 497 after the fix).

**A short window turns "slow" into a false BOUNDED.** A load showed 6.4 MiB at
the 4th second and looked like it had hit a ceiling; in fact the per-second
delta was merely decaying (1250/s -> 400/s) and never plateaued. By the 12th
second it was 24.2 MiB and still growing. Watch the DELTA per interval and run
long enough for it to plateau or fail to.

A flood of frames of any type allocates similarly, so "high RSS at a high frame
rate" is normal, and that is a matter for rate limiting at the deployment level.
Do not ship a defence on rising RSS alone.

## Controls

- **The best control is often a case you have already run.** A client and a
  server in one process make RSS ambiguous: the bench's own send queue counts
  too. Two modes pushing the same volume through the same socket and differing
  only in the stream id cancel out the client-side cost — that is exactly what
  proved the 8x gap was on the server side. Look for the variant that holds the
  bench constant before building a byte-level relay.
- **If the control shows the same symptom as the case under test, the bench is
  wrong, not the library.** That is how a "confirmed" leak evaporated: the
  handler ran 100 x 100 ms = 10 s while the probe observed for 7 s, so both the
  aborted case and the cleanly-finishing control reported "still running". Cut
  to 3 s and they became identical: no defect.
- **Calibrate the control against the observation window** before believing
  either side.
- **Ablation**: switch off one part of the fix at a time, confirming each is
  load-bearing.

## Performance rounds

Performance is a COMPARISON, and comparisons are where the traps bite hardest.

- **Baseline first, and write it down.** A speed-up with no "before" number is
  not a claim.
- **An optimisation needs a canary too**: revert it and re-measure. If removing
  it does not move the number, it was doing nothing.
- **Single measurements on a developer machine are not evidence.** The same
  binary gave 67k -> 116k msg/s between runs. Take medians across RUNS, not just
  within one, and watch the machine's load: a full suite run drives the
  15-minute load average past 16, and wall-clock lies there.
- **Measure what the user pays for**: end-to-end call latency and sustained
  throughput on a real transport. Move to a microbenchmark only after a profile
  or an end-to-end number has named a suspect.
- **Keep an in-memory pair as the CONTROL**: the same stack with no socket. The
  gap between it and the real transport is the transport's cost.
- **Never move a bound for speed.** A fast path that lost its limit is a
  regression. Trading safety for throughput is the owner's decision, not a
  round's.
- **Profile before the third guess.** Two measurements to eliminate hypotheses
  is fine; after that, stop guessing and take a profile of one call.

## Forensics

- **A bisect tells you who takes part, not who is at fault.** Switching off the
  error delivery "fixed" a crash whose real cause was a listener that did not
  handle it.

The rest of the forensics depends on the language and the runtime and lives in
the packs (`packs/dart/measure.md` and so on).
