---
refines: U-15
paths: [packages/transport/*/lib/**, packages/core/rpc_dart/lib/src/resilience/**, packages/core/rpc_dart_framework/lib/**, packages/core/rpc_dart/lib/src/endpoint/**]
applies: something with a lifecycle — an object with start/stop/close/reconnect, or a STREAM opened by a frame — and a suite that drives each step once
breaks: a connection leak; or a running call detached from everything that can stop it.
applied: [241, 401, 487, 503, 562, 573, 576, 599, 627]
status: confirmed (round 487)
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

## Its first application in this journal (round 241)

Driving `reconnect()` twice and asserting the SERVER's state — not the return
value — found a connection leak the suite could not: 5 orphans in 390 cycles,
about 1.3%, always a DISCARDED connection and never the live one. Bench
`../probes/P-19-sequential-reconnect-orphan-rate.md`; deferred as B-25 because
a 1.3% defect has no deterministic witness to canary.

> **A rate is a state assertion too.** The lens says assert the state after the
> second call; when the defect is probabilistic, "the state" is a rate over many
> cycles, and the cheapest thing that turns an unreproducible bug report into a
> finding is counting WHICH object leaked. Here the ordinal is what proved this
> was not the concurrent defect already pinned by a test in the same file.

The clean half of the same sweep is `../checked/C-06-lifecycle-apis-twice.md`.

## Round 401 — drive the REMEDY the second call prescribes

The second call does not always leak or throw silently. Sometimes it throws a
good error that tells the operator what to do — and then the thing to drive is
the instruction, not the API.

`RpcWebSocketServer.start()` refuses to restart over a single-subscription
connections stream and names two remedies. One works and one cannot:

```
arm            first     restart      isRunning   then
single         served    StateError   false       -
broadcast      served    ok           true        served
fresh server   served    StateError   false       -
```

"Construct a new `RpcWebSocketServer`" fails identically, because the obstacle
is the STREAM and not the server object — and over the same `HttpServer` there
is no fresh stream to be had either, `HttpServer` being single-subscription and
already listened to.

> **An error message that prescribes is an API surface, and the lens covers it.**
> Nothing type-checks prose. Drive each remedy it names the way a reader would:
> literally, changing only what the sentence says to change.

And the remedy that works is worth driving one step further, because a restart
has a WINDOW. While the server is stopped the socket underneath keeps accepting
and upgrading, and a broadcast stream with no listener drops the event: the peer
completes its handshake, is never answered and never closed, and waits on its
own deadline. B-59. `../probes/P-87-restart-the-way-the-error-says.md`,
`../rounds/401-the-remedy-that-was-not-one.md`.

## Round 487 — the object with a lifecycle need not be an object

Every application above drives a class with `start`/`stop`/`close`/`reconnect`.
A STREAM has a lifecycle too, it is opened by a FRAME rather than by a method
call, and the peer decides how many times that method is called.

`_handleMetadataMessage` ran for every metadata frame carrying a methodPath,
with no check that the stream was already bound. The second one cleared the
cached context and built a new one — new cancellation token, new `RpcCallScope`,
new deadline timer — while the handler kept the first:

    second HEADERS   handler saw the cancel 0   disposer ran 0
    nothing extra    handler saw the cancel 1   disposer ran 1

> **Widen "lifecycle API" to anything a PEER can invoke twice.** The detector is
> unchanged — create, use, use again — but the inputs are frames, and a peer
> sending the opening frame twice is a ~30-byte message, not a programming
> mistake somebody has to make. The `paths:` above gained the endpoint for this
> reason.

The Ask answers the same way as ever: after the second call, the object's
reported state did not match what it held. `state.cachedContext` named a context
no running code had.

> **And the sibling path had the guard all along.** `_handleDataMessage` opens
> with `if (!state.hasMethod && message.methodPath != null)`; the metadata path
> — the one a peer reaches without sending any payload — did not. When this lens
> finds an unguarded second call, look for the same operation on a neighbouring
> path before designing a guard; here the fix is that condition, moved.

`../probes/P-126-what-a-second-opening-frame-detaches.md`,
`../rounds/487-the-frame-that-swaps-the-handlers-context.md`, B-96.

Imported from private memory in the curate pass after round 234, which is also
what C-06 had been asking for: it recorded shape U-15 as having no lens.

## Drive it twice where the FIRST attempt FAILED (round 503)

The lens as written drives a step twice and both attempts succeed. There is a
second variant, and it found `registerContract`: **drive it, make it throw, then
drive it again.** Every test in the repo registered a contract once and
successfully, so nothing had ever asked what state a failed registration leaves —
and the answer was "the contract, plus however many of its methods were processed
before the throw", with the retry refused as a duplicate.

The detector: for each lifecycle method, list the statements that can throw and the
statements that mutate, and check the ORDER. Every mutation above a possible throw
is a partial commit. Then ask the question that turns it into a defect rather than a
wart — **what recovery does the caller have, and does the debris break it?** Here
the only recovery is catch-fix-retry, and the debris is exactly what refuses it, so
a registration failure was terminal for that service name.

> **The control is a successful call made twice.** Both the defect and correct
> behaviour end in "already registered", so the second error says nothing on its
> own; only the state distinguishes them. A round that reads the exception and stops
> concludes the opposite of the truth.

The fix shape is the same every time: build into a local, check everything, commit
once. Reserving into a `pending` map also lets the operation check itself for
internal conflicts, which removes a dependence on a guarantee held in another class.

`../probes/P-141-what-a-failed-registration-leaves-behind.md`,
`../rounds/503-the-throw-that-left-half-a-service.md`, B-112.

## Round 562 — the lifecycle was driven twice by the CODE, not by a caller

Every application above drives an API twice from outside. Here two internal paths did it: the preface
deadline released the connection's endpoint and then destroyed the socket, whose `done` released it
again. A user's `onConnectionClosed` counted two closes for one connection.

```
  silent, preface deadline    opened=1  closed=2   ->  closed=1
  speaks h2, closes politely  opened=1  closed=1
```

> **Two teardown paths for one resource is the same defect as a caller calling close twice, and
> harder to see — nobody wrote the second call.** The place to look is any teardown that both
> *reclaims* and *destroys*: the destroy is itself an event something else listens for. Ask what the
> socket's own `done` does after you have already cleaned up.

> **The registry you remove from is the idempotency guard you already have.** No new flag was needed:
> `_endpoints` is the list of live connections, so `if (!_endpoints.remove(endpoint)) return;` makes
> the close, the map removal and the callback fire once. A `bool _released` would have been a second
> source of truth about the same fact.

> **The paired half of the lead was REFUTED, and the counting control is what made the refutation
> safe.** `opened=1` in every row says the open callback was never double-fired, so the guard is
> witnessed on the close half only and is not claimed for the other.

`../rounds/562-one-close-became-two-and-the-crash-was-not-there.md`,
`../probes/P-185-two-paths-release-one-connection.md`, B-192.
