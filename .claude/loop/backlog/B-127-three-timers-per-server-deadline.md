---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/core/rpc_dart/lib/src/contracts/call_scope.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
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

## Owner decision

—
