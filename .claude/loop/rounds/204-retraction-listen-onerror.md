---
round: 204
verdict: RETRACTED
packages: [rpc_dart]
lens: RPC-12
bench: none
budget: probes 0/3, canaries 0/3
review: self (record migrated into the schema; the round itself had no review)
commit: yes
---

# Round 204 — the request stream carries cancellation, so listen needs onError

## Target

RPC-12 — cancellation delivered into the handler's request stream

## Hypothesis

(from round 202) cancelling a `clientStream` call kills the isolate.

## Before

```
an ordered timeline with both sides instrumented:

  0 ms  cancel()
  6 ms  the CALLER's future -> RpcCancelledException
  7 ms  an error in the HANDLER's stream, RpcCancelledException
```

Probes: `cancel_zone_trace.dart`, `cancel_shape_matrix.dart` in
rpc_dart_websocket.

## Mechanism

There is no library defect. In the probe, the handler did
`requests.listen((_) {})` with no `onError`. Cancellation is delivered into the
handler's request stream DELIBERATELY, so it learns the call is gone; a
subscription without `onError` turns that delivery into an unhandled error, and
Dart makes such an error fatal to the isolate. Ordinary stream semantics, not a
bug. Handlers on `await for` are unaffected: the error arrives as a throw, which
the responder pipeline already catches. Only the `listen`-without-`onError`
shape dies.

## After

n/a — no code changes; a line was added to the handler contract's documentation.

## Canary

n/a

## Gate

n/a (documentation)

## Not fixed

Nothing.

## Links

Retracts rounds `202-clientstream-cancel-claim.md` and
`203-failed-fix-attempt.md`; the shape is recorded by lens
`../lenses/RPC-12-cancel-into-request-stream.md` with status `retracted`.

## Four theories disproven by measurement — do not try again

1. The scope had already cancelled the send-loop subscription -> gating on
   `hasListener` changed nothing (so a listener WAS there).
2. That subscriber has no `onError` -> it does, and a second one is a compile
   error.
3. Forwarding the request stream duplicates the terminal error -> making it
   idempotent changed nothing.
4. It is a regression from round 201 -> no, the pre-201 order fails identically.

## What found the cause

`runZonedGuarded` around the CLIENT did not catch the error. The server endpoint
is created outside that zone, so a leak belonging to the responder could never
be caught there — one measurement moved the whole search from the caller to the
handler.

## The probe's trap

`RpcContext.withHeaders` does NOT create a cancellation token, so
`ctx.cancellationToken?.cancel()` is a silent no-op. Use
`RpcContext.withCancellation(RpcCancellationToken())`.
