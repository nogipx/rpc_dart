---
round: 337
verdict: FIXED
packages: [rpc_dart, rpc_dart_framework, rpc_dart_http, rpc_dart_http2]
lens: RPC-23
bench: P-36 — new
commit: yes
---

# Round 337 — the class, not the sample

## Target

The owner's, stated twice: log message strings are built even when the level
discards them. Rounds 333 and 334 took the unary path; the owner's correction
was that the question was about **every** logger call. L-12 is the lesson that
round paid for, and its rule is that the count comes FIRST and goes in `Target`.

Counted before any edit, across `packages/core` and `packages/transport`:

```
                                       interpolating   constant
                                          unguarded   unguarded
rpc_dart          16 files                      105          18
rpc_dart_framework rpc_app.dart                   8           1
rpc_dart_http      2 files                        4           2
rpc_dart_http2     3 files                       41           5
                                                ---         ---
                                                158          26
rpc_dart_websocket / _isolate / _wasm             0           0
```

**158 sites, 21 files, 4 packages — that is the scope, all of it.** The 26
constant-message calls are NOT in the class: a const string costs nothing to
build, so a guard on one buys nothing and adds two lines. The three remaining
transports have no `internal`/`trace`/`debug` call at all.

## Hypothesis

The unary rounds measured the smallest shape. The streaming shapes run the same
`base_processor` plus their own caller/responder pair, none of which had a
single guard, so their per-round-trip volume should be several times unary's.

## Before

P-36, per round trip:

```
                no logger attached        LogController at error
             calls/rt  chars/rt        calls/rt  chars/rt
unary             6.0       263             6.0       263
serverStream     42.0      2297            42.0      2297
clientStream     36.0      1976            36.0      1976
bidi             28.0      1632            28.0      1632
```

Two facts the earlier rounds did not have. **Unary was the cheapest shape by a
factor of seven** — 333 and 334 drove the volume on that one path from 35 to 6
and reported the job nearly done, while serverStream sat at 42. And the two
columns are IDENTICAL: **attaching a real logger at `error` level does not stop
one character being built.** The cost is not a property of running without a
logger; it is a property of every call site, on every deployment.

## Mechanism

`LogScope.internal(String message, ...)` takes a String, so the interpolation
runs at the call site before the method is entered — whether the body is empty
(`_NoopLogScope`) or the controller rejects the level two lines in. Dart has no
lazy argument, so the only place to fix this is the call site, and the codebase
already had the remedy: `isInternal`/`isTrace`/`isDebug`, a bool read.

Two idioms, because the field's nullability differs between core and the
transports:

```dart
core        if (_logger.isInternal)           { _logger.internal(...); }
transports  if (_logger?.isInternal ?? false) { _logger?.internal(...); }
```

The transports' `?.` already short-circuits when NO logger is attached, so their
half only ever cost anything with one attached — which, per the table above, is
the ordinary case.

## After

```
                before                    after
             calls/rt  chars/rt        calls/rt  chars/rt
unary             6.0       263             1.0        27
serverStream     42.0      2297             5.0       145
clientStream     36.0      1976             4.0       131
bidi             28.0      1632             1.0        33
```

**94% of the discarded characters gone on the three streaming shapes**, and what
remains is provably free: the residual is exactly the 26 constant-message calls,
which are compile-time constants. At round 333's measured price — 1.95 us per 35
calls / 1583 characters on the VM — serverStream recovers about 2.7 us per round
trip, clientStream 2.3, bidi 2.0, unary 0.3.

The invariant is now greppable, which is the point of sweeping the class rather
than a sample: `internal`/`trace`/`debug` call sites 249, guard blocks 65 ->
222. Every unguarded residual carries a constant.

## Canary

Two, because the two idioms fail differently.

```
core, server/responder.dart      guard -> `if (false)`
                                 Expected: true  Actual: <false>
                                 'server/responder.dart was muted'
                                 THE CALL STILL SUCCEEDS

http2, responder transport       guard -> always-false
                                 Expected: true  Actual: <false>
                                 'responder transport was muted'
```

And the ablation that shows why the second witness had to exist: setting the
http2 guard to `?? true` — the natural way to get the nullable form backwards —
left **every cell of P-36 unchanged**. A core bench cannot see a transport
regression.

`test/logger/guarded_logs_still_reach_an_attached_logger_test.dart` now drives
all four shapes and names at least one line per guarded file;
`rpc_dart_http2/test/guarded_logs_still_reach_an_attached_logger_test.dart` does
the same for the nullable idiom over a real socket.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`; `format:check`
clean; `test:unit` 14 packages, 0 failures — `rpc_dart` `+1443 ~1` -> `+1445 ~1`,
`rpc_dart_http2` `+204` -> `+205`, `rpc_dart_websocket` `+137`.

## Not fixed

**Nothing in the class.** All 158 are guarded.

One failure direction is still unwitnessed, and it is worth naming because the
canary found it rather than reasoning: `if (_logger?.isInternal ?? true)`
over-builds instead of muting, so no assertion anywhere goes red. Only the
counters see it, and they are core-only. A transport-side counter bench would
close it; it was not worth a second apparatus this round.

`LogScope.noop`'s doc carried rounds 333/334's measured table, which this round
made stale. Trimmed to the rule rather than re-stated with new numbers — a doc
comment with a measurement in it reads like evidence and nothing checks it.

## Links

RPC-23 (`applied:` gains 337). L-12 is the rule this round is the first
application of, and the count in `## Target` is what it asks for: taken before
the fix, it showed the two halves are not the same defect (nullable vs not) and
that three transports were not in the class at all — neither of which a
sample-then-extrapolate round would have learned.

> **The smallest shape was measured first and read as the whole.** Unary is the
> only shape with no per-message loop, so it has the least logging of the four;
> two rounds drove it to 6 discarded messages and reported the remainder as a
> tail, while the shape next to it had 42. When a defect is per-call, measure the
> most expensive call before deciding what is left.
