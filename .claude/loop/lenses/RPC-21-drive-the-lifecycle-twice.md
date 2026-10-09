---
refines: U-15
paths: [packages/transport/*/lib/**, packages/core/rpc_dart/lib/src/resilience/**, packages/core/rpc_dart_framework/lib/**, packages/core/rpc_dart/lib/src/endpoint/**]
applies: something with a lifecycle — an object with start/stop/close/reconnect, or a STREAM opened by a frame — and a suite that drives each step once
breaks: a connection leak; or a running call detached from everything that can stop it.
applied: [241, 401, 487, 503, 562, 573, 576, 599, 627, 644, 648, 656, 695, 705, 721, 722, 731, 732, 752, 761, 777]
status: confirmed (round 752)
rank: 2
---

# RPC-21 — Drive the lifecycle twice

## Shape

A suite builds a fresh object per test and calls each method ONCE, on the happy
path. Every defect that needs a second call, or a call after a failure, is
structurally invisible to it — and that is where this repo's lifecycle defects
have all been.

## Detector

For every transport, server and connection wrapper, run:

    create -> use -> use again (many times) -> stop -> start again
           -> stop twice -> start twice
    and separately:  ... -> make it FAIL -> use -> recover

**Assert the STATE afterwards** (`isClosed`, `isRunning`, `health()`), not just
that the call returned. The observable is **counting contract `dispose()`
calls** — `endpoint.close()` -> `RpcResponderRegistry.disposeAll` ->
`contract.dispose()`. A getter that FILTERS can hide the leak you are counting
(`endpoints` filters to `RpcResponderEndpoint`); assert on `dispose()`.

For each lifecycle method, list the statements that can throw and those that
mutate, and check the ORDER: every mutation above a possible throw is a partial
commit. Then ask what recovery the caller has, and whether the debris breaks it.

"Lifecycle API" includes anything a PEER can invoke twice (frames), and two
internal teardown paths for one resource (reclaim plus destroy). Grep the suite
for which teardown it calls: if it is unanimously the escape hatch, the
standard path is untested.

Harness traps: closing a never-listened single-subscription `StreamController`
never completes; fixed-port restarts on macOS flake (ECONNREFUSED/ENETDOWN);
`Socket.connect` is NOT a liveness probe for a just-released loopback port —
send a real HTTP request.

## Ask

After the second call — or the first one after a failure — does the object's
reported state match what it actually holds?

## Evidence

Four consecutive rounds, four defects, none visible to a green suite:
`RpcWebSocketServer.start()` (8ceb9033) set `_isRunning` before the fallible
`listen()` — never set a state flag before the operation that can fail;
`RpcHttpServer` two-phase start (ded7d6ef) left an orphan listener answering
HTTP 503 forever; `RpcWebSocketServer` (4484859f) and `RpcHttp2Server`
(ba8ed409) leaked on a throwing `onEndpointCreated` (3 held, 0 disposed) — any
window between "registered" and "release wiring installed" that contains USER
CODE is a leak; `RpcIsolateTransport.spawn` (eb5f4d47) released the isolate on
`kill()` only, and every test used `kill()` — check what the STANDARD teardown
releases. Cleaning up a failed setup can close a SHARED resource
(`RpcEndpointBase.close()` closes its transport): always drive the RETRY. Family:
`../lessons/L-08-a-per-test-connection-hides-it.md` and
`../lenses/RPC-19-one-flag-two-lifecycle-meanings.md`. Imported from private
memory in the curate pass after round 234, which also answered C-06's note that
U-15 had no lens.

- **Round 241** — driving `reconnect()` twice, asserting the SERVER's state: 5
  orphans in 390 cycles (~1.3%), always a DISCARDED connection. A rate is a
  state assertion too; counting WHICH object leaked separated it from the
  concurrent defect. Deferred as B-25. `../probes/P-19-sequential-reconnect-orphan-rate.md`;
  clean half `../checked/C-06-lifecycle-apis-twice.md`.
- **Round 401** — `RpcWebSocketServer.start()` refuses a restart over a
  single-subscription stream and names two remedies; "construct a new server"
  fails identically. An error message that prescribes is an API surface: drive
  each remedy literally. The working remedy has a restart window where upgraded
  peers hang (B-59). `../probes/P-87-restart-the-way-the-error-says.md`,
  `../rounds/401-the-remedy-that-was-not-one.md`.
- **Round 487** — a second opening metadata frame swapped the handler's
  context: handler saw the cancel 0, disposer ran 0. Widen "lifecycle API" to
  anything a PEER can invoke twice; the sibling `_handleDataMessage` had the
  guard all along. `../probes/P-126-what-a-second-opening-frame-detaches.md`,
  `../rounds/487-the-frame-that-swaps-the-handlers-context.md`, B-96.
- **Round 503** — a failed `registerContract` left the contract and some
  methods behind, and the retry was refused as a duplicate. The control is a
  successful call made twice, since both end in "already registered"; fix:
  build into a local, check everything, commit once.
  `../probes/P-141-what-a-failed-registration-leaves-behind.md`,
  `../rounds/503-the-throw-that-left-half-a-service.md`, B-112.
- **Round 562** — the preface deadline released an endpoint and the socket's
  `done` released it again: `closed=2` for `opened=1`. Two teardown paths for
  one resource is the same defect as calling close twice; the registry you
  remove from is the idempotency guard (`if (!_endpoints.remove(endpoint)) return;`);
  the open half was refuted by the counting control.
  `../rounds/562-one-close-became-two-and-the-crash-was-not-there.md`,
  `../probes/P-185-two-paths-release-one-connection.md`, B-192.
- **Round 752** — an `RpcIsolateModule` worker exited, calls answered status 14
  (3 of 3) and `RpcApp.health()` read healthy via the inherited
  `checkHealth() => null`. An aggregate health report is only as good as the
  members that report. `../rounds/752-a-dead-worker-reads-healthy.md`,
  `../probes/P-257-a-dead-worker-and-what-health-says.md`.
- **Round 761** — the websocket open of rounds 755-756 driven through a failed
  `reconnect()` and back, twice: unhealthy and 14 while down, healthy and `ok`
  once up, both cycles alike. Clean. **A new open path is measured on its
  reconnect, not only its first connect.**
  `../rounds/761-the-bounded-open-reconnects-twice.md`,
  `../probes/P-263-reconnect-through-a-failure-twice.md`.
