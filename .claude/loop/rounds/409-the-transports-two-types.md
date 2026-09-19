---
round: 409
verdict: DEFERRED
packages: [rpc_dart_http2, rpc_dart_websocket]
lens: RPC-24
bench: none — a complete sweep of every reference is the evidence; the user-visible cost is what has no number, and that is why it is deferred
commit: yes
---

# Round 409 — the transports' two types

## Target

The owner's goal names the transports, and round 408 stopped at core. Five
transports declare **two** error types between them:

```
RpcWebSocketNonBinaryFrame   extends RpcException implements IRpcAdvisoryChannelError
RpcHttp2StreamError          class RpcHttp2StreamError { }
```

RPC-24, the surface nobody chose: what a package publishes as its error
vocabulary, and what it does not.

## Hypothesis

`RpcHttp2StreamError` not being an `Exception` is the same defect round 408
fixed in core — a library type outside the hierarchy, invisible to a
default-deny mapper.

## Before

Half right, and the other half is the finding. It is not an error at all, it is
an ENVELOPE, and its own doc says so:

> per-stream errors are added as [RpcHttp2StreamError] envelopes.
> [filterStreamEvents] then re-throws the inner error only on the matching
> stream's subscriber.

So "not an Exception" is correct by design — nobody is supposed to catch it,
because it is unwrapped first.

**Except nothing unwraps it.** Every reference to `filterStreamEvents` in the
repository:

```
lib/  rpc_http2_common.dart:179   its own doc comment
lib/  rpc_http2_common.dart:197   the declaration
test/ http2_hardening_test.dart   x5, against a hand-made StreamController
CHANGELOG.md:158                  describes it as the mechanism
```

Zero production call sites, against two production sites that CREATE the
envelope. The unwrapper is exercised only in isolation, by a test named "BUG B:
per-stream error isolation".

## Mechanism

`wireStatusFor` is default-deny — round 408's subject. An envelope is not an
`RpcException`, so it takes the deny branch and whatever the inner error was,
the peer is told INTERNAL "Internal server error". **The envelope hides its
contents from the one function whose job is to decide what may be forwarded.**

Per-stream routing does not depend on it: both transports already call
`_streams.addError(streamId, error, stackTrace)` with the RAW inner error beside
the enveloped broadcast add. So the envelope serves the broadcast alone, and the
broadcast has no unwrapper.

## After

n/a — deferred.

## Why DEFERRED and not FIXED

Two opposite fixes, and choosing needs a number neither has: wire
`filterStreamEvents` into `getMessagesForStream` and restore the documented
design, or drop the envelope so the broadcast carries a classifiable error.
The second is tempting until you notice that connection-level fatal errors are
added UNENVELOPED on purpose — the envelope is what distinguishes them, which is
the very thing it was introduced to fix.

The measurement that decides it is named in B-62: what a caller is told for a
stream-level transport error that is NOT a framing violation, since the framing
path answers the peer separately (round 397) and masks this one.

Ending the round here rather than guessing is the point. A sweep that names
every reference is evidence; it is evidence about the CODE, not about the cost.

## Canary

n/a — no fix.

## Gate

Not run: no code changed.

## Not fixed

B-62. And the goal's remaining pieces, unchanged from round 408:
`RpcFrameException` extends `RpcException` rather than `RpcStatusException`, so
its eight throw sites report INTERNAL where the framing limits have statuses of
their own — B-58 is the same question at a neighbouring site and is awaiting the
owner, so this stays named rather than touched. And the 83 raw
`StateError`/`ArgumentError` sites still need the reachability split.

## Links

- B-62 — the finding
- Round 408 — the same default-deny mechanism, one layer in
- RPC-24 — the error vocabulary a package publishes, and what it leaves out
