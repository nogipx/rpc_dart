---
round: 674
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-15
bench: none — a code-shape item with no failure to measure, as the lead says; the existing drain test is the witness
commit: yes
release: changelog
severity: S3
---

# Round 674 — the drain reads a number, not a map

## Target

B-151's last item, http1 in the owner's order: `RpcHttpServer`'s graceful stop
polled `health().details['pendingRequests']` -- a stringly-typed read of a map
built for display -- every 25 ms. One site.

## Hypothesis

None about behaviour: the lead calls it a design item with no failure to
measure, and nothing here contradicts that.

## Before

```dart
pending: () async {
  final health = await transport.health();
  return (health.details['pendingRequests'] as int?) ?? 0;
},
```

A renamed key reads 0 and the drain stops waiting, with nothing to say so.

## Mechanism

The count existed only inside `health()`.

## Fix

`RpcHttpResponderTransport.pendingRequests`, a typed getter; `health()` and the
drain both read it.

## After

```dart
pending: () => transport.pendingRequests,
```

## Canary

The getter forced to 0 is what a missing key produced:
`graceful_drain_on_stop_test` "a drained stop lets an in-flight request
finish" red, `Expected: 'returned finished' Actual: 'status 14'`. Restored:
green.

## The verdict questions

1. Yes: the getter's value alone.
2. Yes: finished against status 14.
3. Yes: the in-flight call's outcome.
4. Not zero-valued.
5. Yes, quoted.
6. One half.
7. Yes.
8. None.

## Gate

`analyze`, `test:unit` (15 packages, http +227), `format:check`,
`license:check` green.

## Not fixed

The lead's trailing note -- `shelf_io.serve` passed no TLS and no `shared`, and
no TLS arm on http2 -- names features `RpcHttpServer` does not have, not
defects; features leave the loop by precedent (B-01). Nothing else on B-151.

## Links

Lead `../backlog/B-151-http1-server-lifecycle-defects.md` closed.
Lens `../lenses/RPC-15-remeasure-own-record.md` -- `applied: [..., 674]`.
