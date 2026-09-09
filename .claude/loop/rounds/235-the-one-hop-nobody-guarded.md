---
round: 235
verdict: FIXED
packages: [rpc_dart]
lens: RPC-16
bench: P-14 — new
budget: probes 1/3, canaries 1/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record. Approved 7 of 7
commit: yes
---

# Round 235 — the one hop nobody guarded

## Target

RPC-16, from `next`: derived, never applied — a hypothesis nobody had paid for.
It was imported from private memory in the curate pass after round 234, and this
is the first round to run its detector.

## Hypothesis

A lifecycle flag is read, something slow is awaited, and the result is installed
without asking again — or, the detector's second half, **when the failure path
does fire, is what this code owns CLOSED, or merely dropped?**

## Before

The detector's instance list is 15 sites across the five path globs. Four are
the lens's own calibration (all fixed, all still carrying their in-code
comments), and the sweep of the rest came back clean except for one:

```
  client_connection  _connectWithBackoff   fixed (calibration)
  client_connection  connectTimeout        fixed (calibration)
  websocket          reconnect             fixed (calibration)
  http2              reconnect             fixed (calibration)
  client_connection  attach                guarded: closes an inner that
                                           arrives at a closed proxy
  http/1.1 caller    reconnect             no-op, nothing awaited
  http/1.1 responder reconnect             no-op
  http2 responder    reconnect             no-op
  websocket responder/http2 server         delegate, no await
  isolate VM         spawn                 guarded: both startup failures reach
                                           teardownStartup(), which kills
  isolate WEB        spawn                 guarded: both phases abandon(),
                                           which terminates the worker
  client_connection  detach                <- DEFECT
```

`detach()` awaited `_innerSub!.cancel()` **unguarded**, then closed `_inner`
inside a `try/catch`. The asymmetry is the whole finding: three lines apart,
`_retire` guards its close with `.catchError`, `detach` guards its close with
`try/catch`, and the cancel between them is guarded by nothing.

```
  control        built=2 closed=2 leaked=0 unhandled=0 disposeThrew=false
  cancel THROWS  built=1 closed=0 leaked=1 unhandled=1 disposeThrew=true
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/detach_cancel_throws.dart`
(bench `../probes/P-14-detach-with-a-throwing-cancel.md`).

## Mechanism

`incomingMessages` belongs to a transport the FACTORY built, so its `onCancel`
is user code. A throw there rejects `detach()` before the close runs — in the
one method that owns both. Three damages from one unguarded await:

- the transport is **dropped, not closed**, and nothing can reclaim it: `_inner`
  is never nulled and `dispose()` cannot reach it either;
- `forceReconnect()` runs `detach().then(...)` with **no `onError`**, so the
  rejection escapes to the zone — the ROOT zone in an application, where an
  unhandled async error ends the isolate — and the reconnect never happens
  (`built` stays 1);
- `dispose()` rejects, leaving `_msgCtl` open.

Fixed by guarding the cancel exactly as the close beneath it already was.

## After

Same probe, same rig: the measured arm now matches the control exactly.

```
  control        built=2 closed=2 leaked=0 unhandled=0 disposeThrew=false
  cancel THROWS  built=2 closed=2 leaked=0 unhandled=0 disposeThrew=false
```

## Canary

The `try`/`catch` removed in place. **3 of the 4 new tests failed, the GUARD
passed** — `Expected: a value greater than <1>  Actual: <1>` on the reconnect
witness, plus the close witness and the `dispose()` witness. Restored: 4/4
green. The GUARD passing on both sides is what says the three witnesses isolate
this defect rather than re-checking a neighbour.

## Gate

`melos run analyze` SUCCESS (21 members + rpc_dart_wasm).
`melos run test:unit --no-select` SUCCESS workspace-wide.
`melos run format:check` SUCCESS (`fvm dart format` first, 1 file).
`melos run license:check` REUSE compliant.

## Not fixed

**`forceReconnect()`'s missing `onError` is still missing.** With `detach()`
guarded it can no longer reject, so the hole is unreachable today — but it is
one `await` away from mattering again, and the fix chosen was the one at the
point that renders the wrong verdict rather than both. Recorded rather than
silently widened.

**Reachability is third-party, and should be read that way.** rpc_dart's own
transports expose `incomingMessages` from a `BufferedBroadcastController`, whose
cancel does not throw; reaching this needs a transport the application supplied.
That is the same reachability class as B-17 (a user decorator) and it is a
documented extension point, not an exotic one.

## Links

Lens `../lenses/RPC-16-check-before-await.md` — `applied: [235]`, status
`confirmed (round 235)`; the sweep's clean rows are recorded there.
Bench `../probes/P-14-detach-with-a-throwing-cancel.md` — new, validated by its
control.
Round `234-the-reconnect-nobody-drives.md` — the curate pass after it is what
imported this lens; this is the first round it could route to.
