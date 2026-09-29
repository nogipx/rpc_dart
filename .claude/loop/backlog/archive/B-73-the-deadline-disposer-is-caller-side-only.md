---
status: closed (round 451)
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: —
reason: bench — whether the responder bounds the deadline elsewhere was never measured, so the defect is unproven either way
---

# B-73 — the deadline disposer exists on the caller side only

## CLOSED (round 451) — the responder bounds it one LAYER up. `checked/C-50`.

The lead's own caveat was right: `responder_pipeline` does bound the deadline by
another route. `_ensureResponderContext` arms a timer from `context.deadline`
(`:2006`), and `_onDeadlineExceeded` (`:2042`) cancels the handler's token and
then arms a RECLAIM backstop for a handler that ignores it — which the caller half
does NOT have, so the asymmetry runs the other way from this lead's reading.

Its three questions, answered in order: torn down on expiry, YES; by the
pipeline, not the processor; and the consumer sees an ERROR
(`RpcDeadlineExceededException`), not a clean end. The third was the gate.

```
cooperative, 300 ms deadline    3 items   DeadlineExceeded   responder timer fired
stubborn,    300 ms deadline    3 items   DeadlineExceeded   responder timer fired
CONTROL, no deadline          100 items   CLEAN END          not fired
```

The isolating trick, worth reusing: the caller's exception proves nothing here,
because one `grpc-timeout` header arms a timer on BOTH ends. The observable is the
responder's own log record, which only `_onDeadlineExceeded` emits.

`base_processor.dart` holds two classes. `CallProcessor` (`:895`) is the CALLER
side and owns `_setupDeadlineMonitoring` (`:1321`), wired at `:1003`.
`StreamProcessor` (`:178`) is the RESPONDER side; it has
`_setupCancellationMonitoring` (`:838`) and **no deadline disposer at all**.

`_setupDeadlineMonitoring`'s own doc says why one is needed:

> `RpcCallScope` closes itself when the deadline fires, and a bare close is
> indistinguishable from the server having finished: a server-stream call then
> ends *normally* on expiry, handing the consumer a truncated stream.

That reasoning is written on the caller half and is not implemented on the
responder half.

**This is NOT established as a defect, and that is the whole point of the
lead.** `responder_pipeline` may bound the deadline by another route, and nobody
has looked. B-70 carried it for 26 rounds inside a claim that "the copies
agree", which it is not — the copies are one copy and an absence.

What a bench has to answer, in order: does a responder-side call with a deadline
get torn down on expiry at all; if so by what; and does the handler's consumer
see an error or a clean end. Only the third question decides whether this is
round-worthy.

## Owner decision

**Take it as a measurement, in the lead's three-question order.** The third
question is the gate: only "the handler's consumer sees a clean end" makes this
round-worthy.

If the responder IS unbounded, the disposer does NOT get copied from
`CallProcessor` into `StreamProcessor`. It goes somewhere both halves inherit —
a fourth hand-written copy of a lifecycle rule is how this lead came to exist.

If the responder bounds the deadline by another route, that route gets written
down in `checked/` with its name, so the next sweep does not re-file the
absence as a finding.

Tearing down a handler that runs past its deadline is a behaviour change on the
server side and needs a CHANGELOG line if it lands.
