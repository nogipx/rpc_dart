---
status: awaiting owner
round: 519
commit: eb42e917
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/core/rpc_dart/lib/src/contracts/call_scope.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: P-156
reason: "CONFIRMED in shape, refuted in its number — a deadline costs 2 timers on unary and 5 on a server stream, not three, and a server stream arms NINE before any deadline exists. Consolidating deadline ownership spans three layers on a hot path and cannot be designed from this measurement; the disposer-timeout half is separable and cheap"
---

# B-127 — a server call arms three timers and two token listeners for one deadline

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`state.armDeadline`, the context's `RpcCallScope` and the StreamProcessor's own `RpcCallScope` each arm an `RpcLongTimer` (plus the half-open timer); `RpcCallScope.close` wraps every disposer in `.timeout(5s)`, allocating a Timer even for synchronous ones; `disposerTimeout` is a mutable static.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart:51-62`, `call_scope.dart` `_wireDeadline`,
`_close` (`Future.value(...).timeout(disposerTimeout)`), `static Duration
disposerTimeout`; `base_processor.dart:243` (`_scope = RpcCallScope(context:)`).

## Why it matters

Timer churn per call and a process-wide knob that any test or library can change.

## Witness a round would build

Timers created per unary call with a deadline (count via a zone).

## Fix sketch

One deadline owner per call; time out only asynchronous disposers.

## Outcome (round 519) — confirmed in shape, refuted in its number

Counted in a Zone, which is the only place that sees every Timer:

```
unary, WITH a deadline               4.0 timers/call
CONTROL unary, no deadline           2.0 timers/call
server stream, WITH a deadline      14.1 timers/call
CONTROL server stream, none          9.1 timers/call
```

**A deadline costs 2 timers on unary and 5 on a server stream** — not three, and not
a constant across shapes.

**The control holds the surprise: a server-stream call arms NINE timers before any
deadline is involved.** That is bigger than the thing this lead is about and is not
what this lead is about.

Both secondary claims verified by reading: `static Duration disposerTimeout` is
mutable process-wide, and `call_scope.dart:229` wraps EVERY disposer in
`.timeout(disposerTimeout)` — so a synchronous disposer allocates a Timer to bound
work that cannot block.

**A rig note**: the first version built the endpoints outside the counted zone and
reported `1.0 timers/call` for unary, deadline apparently free. A subscription
creates its timers in the zone it was registered in, so every RESPONDER timer was
uncounted — the half this lead is about.

## Owner decision

**"One deadline owner per call" cannot be designed from this measurement.** Knowing a
deadline costs 2 or 5 timers does not say which of the three arming sites is
redundant, and the three sit in different layers (`responder_streams`, `call_scope`,
`base_processor`) with different lifetimes and teardowns. It is a change to how a
call's cancellation is OWNED, on a hot, well-tested path. Round 518 is the immediate
precedent for not attempting that on partial information.

**Three separable pieces, cheapest first:**

1. **Time out only ASYNCHRONOUS disposers.** `Future.value(x).timeout(d)` allocates a
   Timer for a value already available; check whether the disposer returned a Future
   before wrapping. No deadline ownership involved, and it wants its own before/after.
2. **`disposerTimeout` as a mutable static.** Any test or library in the process can
   change it for everyone. A small API decision.
3. **Consolidate deadline ownership**, which is the expensive one above, and would
   want the arming sites attributed first — a stack capture per Timer creation, which
   this round did not build.

**And the nine-timer floor on a server stream is unexplained**, larger than everything
above, and nobody has looked at it.
