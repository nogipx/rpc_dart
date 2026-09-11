---
round: 333
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none
commit: yes
---

# Round 333 — strings built for a logger that discards them

## Target

The owner's, given mid-run: log message strings in core are built even when the
minimum level is above `internal`, and that costs CPU.

## Hypothesis

True, and worth quantifying: `LogScope.internal(String message, ...)` takes a
STRING, so Dart evaluates the interpolation at the call site before the method
is entered. An endpoint with no logger uses `LogScope.noop`, whose `internal`
body is empty — so on the default configuration every one of those strings is
built, allocated and dropped.

## Before

Counted by instrumenting `_NoopLogScope.internal`, over 2000 unary round trips
on an in-memory pair with no logger attached:

```
discarded internal() calls   35.0 per round trip
discarded characters       1566   per round trip
                          70000 calls / 3.13 MB over the run
```

Priced in isolation, rebuilding the real message shapes at that volume
(`.dart_tool/probe/interpolation_cost.dart`):

```
                         VM        dart2js
building them          2.3 us      3.5 us    per round trip
behind a false guard   0.35 us     0.00 us   per round trip
```

So ~2.0 us of pure CPU per round trip on the VM, ~3.5 us on dart2js.

**The end-to-end wall clock cannot see it, and that is worth stating.** Two runs
of identical code measured 174.4 and 184.9 us per call — a 6% spread against a
1.2% effect. Only the counters and the isolated benchmark are valid instruments
here.

A histogram of the discarded messages showed the cost is FLAT: the top shape
fires 2.2 times per round trip and the rest about 1.1 each, across ~30 distinct
sites. There is no concentrated hot spot to fix cheaply.

The codebase already knows the remedy — `isInternal`/`isTrace`/`isDebug` exist
with the comment "Level guards for hot-path optimization" — and uses it at 25
sites out of 58 that interpolate. `unary/responder.dart`, the per-call responder
path, had 38 `internal(` calls and **zero** guards.

## Mechanism

`LogScope.noop`'s own doc comment said:

```dart
/// No-op logger. All methods are empty, zero cost.
```

The methods are empty. The CALL is not free, and that sentence is exactly what
tells a reader not to bother guarding. Rule one: prose that contradicts the code
is a defect, fixed in the same round.

## After

Sixteen per-call sites in `unary/responder.dart` guarded:

```
discarded internal() calls   35.0  ->  25.0   per round trip
discarded characters       1566    -> 1187    per round trip
```

29% of the discarded volume on the unary path, ~0.6 us of CPU per round trip.
`LogScope.noop`'s doc now carries the measurement and points at the guards.

```
rpc_dart   +1439 ~1  ->  +1440 ~1
```

## Canary

A guard muted to `if (false)` — the failure mode that matters, because a guard
reading the wrong level deletes the logging for everyone and nothing else
asserts these lines are emitted:

```
guard intact   test passes
if (false)     Expected: true  Actual: <false>, and the CALL STILL SUCCEEDS
```

`test/logger/guarded_logs_still_reach_an_attached_logger_test.dart` attaches a
real `LogController` at `internal` level and asserts three of the sixteen lines
arrive.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`;
`format:check` clean; `test:unit` 14 packages, 0 failures — `rpc_dart`
`+1440 ~1`, `rpc_dart_http2` `+204`, `rpc_dart_websocket` `+137`.

## Not fixed

**25 discarded messages per round trip remain**, spread across roughly 20 sites
in `base_processor.dart`, `unary/caller.dart`, `caller_pipeline.dart`,
`channel_transport.dart` and the parser — about 1.4 us of CPU per call. The fix
is the same mechanical guard and the shape is now proven; it was not finished
here because it is ~40 more edits on files this round did not otherwise touch,
and the round's measurement is what makes that work worth deciding on.

**Whether it is worth doing at all is a judgement about deployment, not about
the code**, and the two framings differ enough to matter: 2.0 us is 1.2% of a
round trip on an in-memory pair, and it is also ~20% of one CPU core at 100k
calls/second. The first number says ignore it; the second says finish it.

## Links

RPC-23 (`applied:` gains 333) — the lens is about prose beside the code, and
"zero cost" is the strongest form of it: a doc comment that is not merely stale
but actively causes the defect it describes away.

The probes are `.dart_tool/probe/discarded_log_strings.dart` (volume; needs the
two counters re-added to `_NoopLogScope.internal`, which were removed before
committing because they would have been a public API addition) and
`.dart_tool/probe/interpolation_cost.dart` (price; standalone, no
instrumentation).

> **The instrument changed between the before and the after, and it took a
> contradictory number to notice.** The first re-measure read 183 us against a
> 166 us baseline — slower after a change that removes work. The cause was the
> per-call `Map` insert I had added to the probe for the histogram, costing
> ~18 us per round trip: nine times the effect under measurement. Re-measure
> with the instrument the baseline used, or the baseline is not a baseline.
