---
round: 606
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-156 — reused
budget: probes 0/5, canaries 0/5
commit: yes
release: changelog
severity: S3
---

# Round 606 — eight timers for disposers that cannot hang

## Target

B-210, the owner's split from B-127: a server stream arms nine timers with no
deadline set, and round 519 counted them without attributing them. The lead asked
for exactly that attribution.

## Hypothesis

Several of the nine are one bound expressed repeatedly, so the per-call floor can
come down without losing any bound.

## Before

P-156 with each timer keyed by its first rpc_dart frames and its duration:

```
CONTROL server stream, no deadline     9.1 timers/call
  3.0  5000ms  RpcCallScope._close  <-  StreamProcessor.close
  3.0  5000ms  RpcCallScope._close  <-  CallProcessor.close
  2.0  5000ms  RpcCallScope._close  <-  RpcCallScope.close
  1.0  60000ms armHalfOpen
server stream, WITH a deadline        14.1 timers/call
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/b127_timers_per_call.dart`, endpoints
built inside the counting zone (round 519's trap).

## Mechanism

`RpcCallScope._close` wrapped EVERY disposer in `.timeout(disposerTimeout)`,
synchronous ones included, so each disposer of each scope armed a 5 s timer. A
synchronous disposer cannot hang; the bound only means anything for one that
returns a Future.

## After

```
CONTROL server stream, no deadline     1.1 timers/call   (armHalfOpen only)
server stream, WITH a deadline         5.0 timers/call
unary, no deadline / with              1.1 / 4.0         (unchanged)
```

Only a disposer that returns a Future is bounded. **The `await` stays for the
synchronous ones** — see Canary 3: later disposers depend on the turn it gives the
earlier ones.

## Canary

1. The unconditional wrap restored: `a server-stream call with no deadline arms only
   its half-open timer` fails, `Expected: < 2, Actual: <9.05>`.
2. No bound at all (await the Future, no timeout): `GUARD: an async disposer that
   hangs is still abandoned` fails, `a hanging async disposer blocked close()`, and
   so do two tests in `call_scope_disposer_timeout_test` (`responder.close() hung`).
3. The first version dropped the await for synchronous disposers. **Twelve existing
   cancellation tests went red** — `cancellation_header_reserved_test`, `the
   cancellation notice no longer reaches the server`; `handler_cancellation_leak`,
   `186 -> 413` messages after cancel; `client_cancellation_token`, `handler token
   never fired` — because a later disposer tears down what an earlier one's cancel
   notice still needs a turn to use. That is the hop's witness.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (15 packages, rpc_dart
+1910, websocket +250, http2 +275), `melos run format:check`, `melos run
license:check` — green. Both disposer test files pass on `-p node`.

## Not fixed

The deadline arm's five: three `_wireDeadline` per server-stream call (one per
scope, three scopes) plus the responder's own deadline and half-open timers. That
is B-127's "deadline ownership across three layers", which this round did not
touch.

## Q8

A rule that holds outside this repo, paid for with twelve red tests in one gate:
**an `await` on an already-complete value is not free to remove** — it yields a
turn, and code after it may depend on that turn. Recorded here, not as a lesson:
the gate caught it at no shipped cost.

## Links

Lead `../backlog/B-210-a-server-stream-arms-nine-timers-before-any-deadline.md` — closed.
Bench `../probes/P-156-how-many-timers-does-a-call-arm.md` — reused, attribution added.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [606]`.
Test `packages/core/rpc_dart/test/contracts/a_call_arms_no_timer_it_does_not_need_test.dart`.
