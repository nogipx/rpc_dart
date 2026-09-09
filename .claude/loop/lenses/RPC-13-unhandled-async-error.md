---
refines: U-17
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: there are paths that run user code outside a guarded zone
breaks: a process crash.
applied: []
status: swept here (round 121, off-journal)
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
