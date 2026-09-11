---
refines: U-17
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: there are paths that run user code outside a guarded zone
breaks: a process crash.
applied: [222, 225, 242, 330, 346, 347]
status: confirmed (round 242)
---

# RPC-13 — An unhandled async error is fatal to the isolate

Anything added to an accept loop or to a stream's event handler runs in the root
zone — ask what a platform accessor does on malformed input BEFORE putting it
there.

## Shape

A future running user code is abandoned with no error handler; in Dart that
kills the whole isolate.

## Detector

Calls that spawn a future without `await` and without `.catchError`, on paths
that run user code: dispatch, lifecycle callbacks, connection accept loops.

## Ask

If this throws, who catches it? Is there a zone, and is it the right one?

## Evidence

One hole found and closed; a sweep across all five transport packages showed
every other site was already guarded.

Round 222 re-ran it, because the 121 sweep is off-journal and rounds 206-212 had
added new `unawaited(...)` calls to exactly these paths. Roughly 85 sites; every
one on a path the detector names is guarded, including all of the new ones:

    _detached / _detachedDispatch              .catchError
    bidi dispatch (both zero-copy and typed)   try/catch inside
    http2 error trailer, refusal, reset        try/catch or .catchError
    http2 GOAWAY fan-out                       .catchError
    websocket upgrade refusal                  .catchError
    channel_transport grant sends              try/catch in _fcSendGrant

But the ablation found something the reading could not:

    _detached's .catchError removed, core suite   +1395 ~1, all passed

## Round 242 — the re-sweep found the THROWER, not the site

Ten files had moved under these paths since 222. Every `unawaited(...)` was
still guarded, and the defect was one level in: `forceReconnect()` runs
`detach().then((_) { _emit(...); ... })` with no `onError`, and `_emit` called
the user's `onStateChanged` with no guard. Round 235 had made `detach()` unable
to reject, so the call site was safe by a property of a different method — and
that says nothing about what the callback inside it does.

    arm                     unhandled  transports built
    control                     0            2
    onStateChanged throws       1            0     <- before
    onStateChanged throws       0            2     <- after

> **Ask who THROWS on the path, not only who catches.** A site with no handler
> is only a defect if something on it can throw; a site whose thrower is USER
> code is a defect the day the API is published. Bench
> `../probes/P-20-throwing-state-callback.md`.

> **A sweep proves the sites are guarded today; it says nothing about
> tomorrow.** The guard here exists because a client hanging up killed two
> production replicas, and deleting it changes nothing any test can see. Ask of
> every guard this lens confirms: what would notice if somebody removed it?
> `../backlog/B-20-detached-guard-has-no-witness.md`.
