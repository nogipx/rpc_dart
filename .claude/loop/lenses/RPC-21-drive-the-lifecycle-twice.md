---
refines: U-15
paths: [packages/transport/*/lib/**, packages/core/rpc_dart/lib/src/resilience/**, packages/core/rpc_dart_framework/lib/**]
applies: an object has start/stop/close/reconnect and a suite that builds a fresh one per test
breaks: a connection leak.
applied: []
status: confirmed (round 77, off-journal)
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
that the call returned. The observable that made this measurable across servers
is **counting contract `dispose()` calls** — `endpoint.close()` ->
`RpcResponderRegistry.disposeAll` -> `contract.dispose()` — so "every endpoint
the server built was released" is a fact the library itself defines, far better
than poking at ports.

> **A getter that FILTERS can hide the very leak you are counting.** The peer
> branch of the websocket server leaked identically to the responder branch but
> looked clean, because `endpoints` filters to `RpcResponderEndpoint`. Assert on
> `dispose()`, not on the public list.

## Ask

After the second call — or the first one after a failure — does the object's
reported state match what it actually holds?

## Evidence

Four consecutive rounds, four defects, none visible to a green suite.

- **`RpcWebSocketServer.start()` (8ceb9033)** set `_isRunning = true` BEFORE the
  fallible `listen()`, so a failed restart reported RUNNING with no subscription
  and clients hung. **General rule: never set a state flag before the operation
  that can fail.**
- **`RpcHttpServer` two-phase start (ded7d6ef).** `stop()` returned early on
  `!_isRunning`, which is set on the line AFTER the bind, so every partial state
  was unreachable to cleanup: a failed bind left the started endpoint
  unreleasable (`disposed=[] endpoints=1`), and a second `afterModulesStart()`
  orphaned the first listener, which kept answering **HTTP 503 on its port
  forever**.
- **`RpcWebSocketServer` (4484859f) and `RpcHttp2Server` (ba8ed409), the same
  defect in both.** `_handleConnection` does `_endpoints.add(endpoint)` ->
  **user callback** -> `endpoint.start()` -> install the release wiring. A
  throwing `onEndpointCreated` left the endpoint registered, never started, and
  unreclaimable: 3 connections, **3 held, 0 contracts disposed**; 0 held and 3
  disposed after. **Any window between "registered" and "release wiring
  installed" that contains USER CODE is a leak** — and a throwing
  `onEndpointCreated` is ordinary, not exotic, because it is where contracts get
  registered, so DI failures land exactly there.
- **`RpcIsolateTransport.spawn` (eb5f4d47)**, a sub-shape worth reaching for
  first: **when an API hands back both a standard lifecycle method and an
  escape-hatch teardown, check what the STANDARD one releases.** `spawn()`
  returns `(transport, kill)`; the isolate and its two ports were released by
  `kill()` alone, while applications take `close()` — so the ordinary path leaked
  a whole isolate per connection and the host process could never exit. **Every
  test in the package tore down with `kill()`**, which is why 60 green tests
  never saw it. Grep the suite for which teardown it calls: if it is unanimously
  the escape hatch, the standard path is untested.

The two other members of this family have their own records:
`../lessons/L-08-a-per-test-connection-hides-it.md` (keep calling on ONE
connection) and `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` (call
`reconnect()` twice).

> **Cleaning up a failed setup can close a SHARED resource.**
> `RpcEndpointBase.close()` closes the transport it was given, so the first fix
> for the two-phase start made the ordinary retry-on-busy-port bind fine and
> then answer 503 to every call — worse than the leak. Rebuild what you closed,
> and always drive the RETRY, not just the failure.

**Test-harness traps hit while doing this**, each of which cost a wrong answer:

- Closing a never-listened single-subscription `StreamController` never
  completes, and hangs teardown.
- A fixed-port server restart on macOS gives flaky ECONNREFUSED/ENETDOWN; prefer
  a factory that fails by construction when you need determinism.
- **`Socket.connect` is NOT a liveness probe for a just-released loopback
  port.** Ephemeral source ports land in the same range, so connect()
  intermittently succeeds against itself — the same port measured `tcp=true` and
  `tcp=false` within one run, which nearly sold a fixed leak as still-leaking.
  Send a real HTTP request: that distinguishes "a server answered" from "some
  socket accepted".

The clean half of the same sweep is `../checked/C-06-lifecycle-apis-twice.md`.

Imported from private memory in the curate pass after round 234, which is also
what C-06 had been asking for: it recorded shape U-15 as having no lens.
