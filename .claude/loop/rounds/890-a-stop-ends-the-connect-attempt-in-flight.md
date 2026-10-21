---
round: 890
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-16
bench: P-341 — new
commit: yes
severity: S1 — "a call, connection or shutdown that hangs with no bound"
release: changelog
---

# Round 890 — a stop ends the connect attempt in flight

## Target

Open lead B-305 (rank 6): `RpcClientConnection.dispose()` does not reach a
factory call still in flight. Websocket is the owner's priority after core,
and I-5 (resources return) is the invariant. Not measured before.

## Hypothesis

`dispose()` and `disconnect()` set flags and close the proxy; the connect loop
reads the flag only before and after its awaits, and nothing interrupts the
await itself. So a websocket upgrade a peer never answers keeps its socket
open after dispose() until the transport's `connectTimeout`, and for good with
`connectTimeout: null`, which the docs offer. Fails if the socket ends within
a few ms of dispose().

## Before

P-341 (`rpc_dart_websocket/.dart_tool/probe/r890_dispose/probe.dart`), a raw
listener that accepts TCP and never answers, `dispose()` 200 ms in:

```
control (handshake answered)          dispose 4-7 ms   socket ended 5-8 ms
handshake silent, default timeouts    dispose 0 ms     socket ended 29802 ms
handshake silent, both timeouts null  dispose 0 ms     still open at 60 s
```

A second defect on the same path, found by the witness (canary 4 below): with
`connectTimeout: null` and a stuck attempt, `disconnect()` then `connect()`
never came back Online -- the old loop still held its guard on the attempt.

## Mechanism

RPC-16: the stop flag is read around the await, not during it. The factory
type `Future<IRpcTransport> Function()` gives the connection no way to tell a
factory to stop, and the loop gave no way to stop waiting on it. The
`ready` wait after the factory returns had the same gap, though there the
transport is already in hand.

## After

Core (`client_connection.dart`):
- `RpcClientConnection.cancellable(transportFactory: (RpcCancellationToken)
  => ...)`, a new named constructor (owner's choice: a public parameter, not a
  zone value). The plain constructor redirects to it and is unchanged.
- One token per attempt, cancelled by `dispose()`, `disconnect()`, and a
  single timer at `connectTimeout` covering the factory and `ready` together.
- The loop races the factory and `ready` against the token. A factory that
  answers late is closed on arrival; a transport already delivered and not yet
  ready is closed at once. A stop is not a failure: it is neither counted nor
  shown to `shouldReconnect`; the loop leaves, or starts a fresh attempt if a
  `connect()` came since.

Websocket: `connect(cancellationToken:)`. `openWebSocket` takes the token's
future; on the VM a cancel force-closes the attempt's own `HttpClient` (the
path `connectTimeout` already used), on the web it closes the channel; then
`connect` throws `RpcCancelledException` (no uri in the text: a web client's
token sits in the query).

P-341 after: cancellable 0-8 ms, unbounded included. The plain constructor
keeps the factory's socket until the transport's own timeout, as documented
on it, but the loop no longer waits.

API: `docs/api/rpc_dart.txt` gains one line, the new constructor; no line
changed or removed (`api:check` shows only "Added"). Skill
`errors-and-resilience.md` and the websocket README describe it; the README
block was compiled by hand (no gate compiles READMEs).

## Canary

Core, `a_stop_ends_the_attempt_in_flight_test.dart`, each half switched off in
place:
1. readiness race replaced by `await inner.ready`: WITNESS "dispose closes a
   transport still waiting to be ready" red, "Expected: true Actual: <false> a
   transport the attempt already held stayed open after dispose". The first
   run of this canary PASSED: the factory branch's discard closed the
   delivered transport as a side effect. The branch now discards only a
   transport not yet delivered, and the canary bites.
2. `dispose()` without `_attempt?.cancel`: "dispose closes a transport..." and
   "dispose cancels the token of a factory still working" red (Expected true,
   Actual false).
3. the deadline timer not cancelling: "connectTimeout cancels the token of the
   attempt it ends" red.
4. `disconnect()` without `_attempt?.cancel`: "connect after a disconnect
   mid-attempt comes back online" red, "the stuck attempt held the loop, so
   connect() never started a new one".

Websocket, `a_cancelled_connect_closes_its_socket_test.dart`: the token not
passed to `openWebSocket`: "Expected: RpcStatusException with statusCode <1>
Actual: 'pending'". Restored: every witness green.

## Gate

`melos run analyze`, `test:unit:quiet --no-select`, `format:check`,
`license:check`, `api:check` (after `api:update`), `check:skills`: green.
`melos run test:web`: first run RED, 45 failures, all `RpcRateLimiter` failing
to construct on node -- round 888's `Random.secure()` salt, committed in
`0d404ad9` without a `-p node` run. Fixed in its own commit (a fallback to
`Random()`, the idiom `RpcContext` already uses for node); `test:web` then
green. The websocket rpc_dart_websocket suite: `+300`.

## Siblings

- websocket: fixed here (P-341).
- http2: fixed for `connect` by the core change alone — P-342, plain
  constructor, silent listener: 29802 ms and "still open at 40 s" with the
  readiness race off, 6 / 0 ms with it on. NOT fixed for `secureConnect`:
  still open at 40 s with default timeouts (one run, fix in place), the TLS
  handshake being inside the factory. B-309, B-310.
- http: n/a — `RpcHttpCallerTransport` opens a request per call; it holds no
  connection-time handshake a factory waits on.
- isolate: n/a — the peer is an isolate this process spawns, not a remote
  that can accept and stay silent.
- wasm: n/a — the peer is a guest this process loads, same reason.
- channel: n/a — the in-memory pair has no remote peer.
- caller: fixed here — `RpcClientConnection` is caller-side.
- responder: n/a — a responder runs no connect loop.
- (not a group member) socket: fixed by the core change alone — P-342: 29808 ms
  and "still open at 40 s" off, 12 / 2 ms on. Its factory returns before the
  preface, so the stage is `ready`. Its TCP connect stage: B-310.

## Not fixed

- B-309: http2 TLS handshake outlives `connectTimeout`.
- B-310: socket and http2 callers take no token, so their factory stages (TCP
  connect to a black hole, proxy CONNECT, TLS) still outlast a dispose.
- The plain constructor cannot end a factory's work; documented on it.

## Links

B-305, B-309, B-310, round 888 (the web regression), RPC-16, RPC-28, I-5,
L-18, L-21.
