---
status: open
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: —
reason: bench — whether the responder bounds the deadline elsewhere was never measured, so the defect is unproven either way
---

# B-73 — the deadline disposer exists on the caller side only

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

—
