# Measurement discipline

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
