---
round: 401
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-21
bench: P-87 — new
commit: yes
---

# Round 401 — the remedy that was not one

## Target

`RpcWebSocketServer`, the owner's priority transport and a file the loop had
never taken. RPC-21: drive every lifecycle API twice. `start()` refuses to
restart over a single-subscription connections stream and throws a `StateError`
that PRESCRIBES what to do instead — so the round takes the library at its word
and drives each remedy it names.

The message:

> Pass a broadcast stream (`Stream.asBroadcastStream()`) if the server must
> restart, or construct a new `RpcWebSocketServer`.

## Hypothesis

`asBroadcastStream()` cancels its source when the last listener leaves, so the
prescribed remedy produces exactly the state `start()`'s own comment warns
about — running, accepting nothing.

## Before

Refuted on the broadcast half. P-87, new:

```
arm            first     restart      isRunning   then
single         served    StateError   false       -
broadcast      served    ok           true        served
fresh server   served    StateError   false       -
```

The broadcast remedy works. **The other one does not.** "Construct a new
`RpcWebSocketServer`" throws the identical error, because the obstacle is the
STREAM and not the server object — and over the same `HttpServer` there is no
way to build a fresh connections stream either, since `HttpServer` is itself
single-subscription and `rpcWebSocketConnections` already listened to it. So
over one bound socket that clause has no working reading at all.

RPC-23's strongest form, round 364's: prose naming a component that cannot do
the job, refutable from the component's own capabilities.

## Mechanism

The second arm drove what the WORKING remedy costs, which the message did not
mention:

```
a peer arriving while a restartable server is stopped
  handshake        accepted
  closed 3 s later NOTHING
  a call over it   HUNG
  after restart    served
```

`stop()` cancels the subscription; the `HttpServer` is not the server's to
close, so it keeps accepting and `rpcWebSocketConnections` keeps upgrading; a
broadcast stream with no listener DROPS the event. The peer completes the
handshake, gets no answer, no close frame and no status, and waits on its own
deadline — `connectTimeout` cannot help, because the connect succeeded.

An ordinary rolling restart reaches it: `stop(drainTimeout:)` then `start()`.

## After

The message now names the stream as the thing to change, says plainly that a new
server over the same stream does not help, and states the gap in the remedy it
does recommend.

Not fixed in code: answering that peer means a stopped server keeps reading its
stream in order to CLOSE what it cannot serve, which inverts the
`_connectionsSub?.cancel()` that `stop()`'s own comment calls load-bearing, and
costs restartability over a single-subscription stream for good. B-59, owner
decision.

## Canary

`restart_needs_a_new_stream_test.dart`, and the file is explicit about which of
its four tests witnesses what — because only one does. The message assertion is
the witness for the change; the other three establish the FACTS the message now
states and passed before it too. Saying so in the file is the point: three
green tests beside a doc fix would otherwise read as three witnesses.

The B-59 baseline test carries its own inversion instruction — if a stopped
server ever does close what it cannot serve, that expectation is the thing to
flip.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant (1521 files); workspace suite **SUCCESS in all 14
packages**, rpc_dart_websocket **+177**.

Analyze caught the test's first version: an `onError` handler that must return
`bool` and ended without returning, which is RPC-26's raised-floor territory
finding a real slip in new code.

## Not fixed

B-59. And P-87 does not ask whether `RpcHttp2Server` has the same window — it
rebinds its own socket, so it is a different shape and deserves its own arm.

## Links

- RPC-21 — the lens; `applied:` gains 401
- RPC-23 — what the defect turned out to be: prose naming a remedy that cannot work
- B-59 — the gap in the remedy that does work
- P-87 — new
