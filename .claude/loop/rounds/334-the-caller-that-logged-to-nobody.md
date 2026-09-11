---
round: 334
verdict: FIXED
packages: [rpc_dart]
lens: RPC-04
bench: none
commit: yes
---

# Round 334 — the caller that logged to nobody

## Target

Round 333's own "Not fixed": 25 discarded log messages per unary round trip
remained, ~1.4 us of CPU, across roughly twenty sites the round named. Finishing
a piece of work already started beats opening a new one.

## Hypothesis

Mechanical. Guard the rest with the same `if (_logger.isInternal)` idiom, get the
count near zero, done.

## Before

```
discarded internal() calls   25.0 per round trip
discarded characters       1187   per round trip
```

## Mechanism

The guarding went as expected — `unary/caller.dart` (11 sites),
`base_processor.dart` (8), `core/parser.dart` (1), plus four more in
`unary/responder.dart` that round 333 had missed.

**Then extending the witness to cover the newly-guarded files failed, and that
is the round.** Round 331 and 332 established the rule that a guard is only
watched where a test names a line behind it, so round 333's witness — three
lines, all in the responder — had to grow. It went red immediately:

```
Expected: true
  Actual: <false>
  the unary caller was muted
```

Not muted by a guard. `UnaryCaller` was being constructed with **no `logger:`
argument at all**, so `_logger` fell back to `LogScope.noop` and every one of
its twenty-odd `internal(...)` calls had been dead for every user since the
class was written. Attaching a `LogController` did not make them appear.

```dart
// caller_pipeline.dart, inside one `handler:` closure
if (isZeroCopy) {
  final processor = CallProcessor<TRequest, TResponse>(
    ..., logger: _log,          // <- zero-copy branch: logged
  );
  ...
}
return UnaryCaller<TRequest, TResponse>(
  ..., transferMode: transferMode,
                                  // <- serialized branch: NOTHING
).call(req);
```

The two branches of one `if`, eight lines apart. The zero-copy path logs; the
serialized path — **the default for every codec-based unary call** — does not.
Every other construction site in both pipelines passes its logger: the three
stream callers at 491/539/614 and all seven responders.

## After

```
discarded internal() calls   25.0  ->  6.0   per round trip
discarded characters       1187    -> 263    per round trip
```

Against round 333's starting point: **35.0 -> 6.0 calls and 1566 -> 263
characters, 83% of the discarded volume gone**, about 1.7 us of CPU per round
trip recovered on the VM by round 333's isolated price.

And the unary caller's diagnostics exist for the first time.

## Canary

The witness now names six lines across responder, caller and parser, and each
was verified to be the thing that fails:

```
guard muted to `if (false)` (round 333)   Expected: true  Actual: <false>
logger: _log removed again                Expected: true  Actual: <false>
                                          'the unary caller was muted'
```

In both cases the CALL STILL SUCCEEDS — which is why nothing had noticed.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`;
`format:check` clean; `test:unit` 14 packages, 0 failures — `rpc_dart`
`+1440 ~1`, `rpc_dart_http2` `+204`, `rpc_dart_websocket` `+137`.

## Not fixed

Six discarded messages per round trip remain, ~0.34 us, in paths this round did
not touch. The volume is now small enough that the next guard is worth less than
the diff it costs.

## Links

RPC-04 (`applied:` gains 334) — a capability dropped on one branch of a wrapper
is exactly its shape, and this is the first time it has been found in a
CONSTRUCTOR ARGUMENT rather than in a transport wrapper. The lens's detector
asks which capabilities a wrapper forwards; the same question applies to which
collaborators a factory passes on.

> **Two branches of one `if` are two call sites, and the shorter one is the
> default.** Nothing distinguishes them to a reader — no type differs, no
> analyzer rule fires, both compile — and the branch that was missing its
> logger is the one taken by every ordinary call.

RPC-23 for round 333's half, and the measurement that made this round worth
starting.
