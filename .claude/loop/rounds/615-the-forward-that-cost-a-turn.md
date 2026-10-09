---
round: 615
verdict: FIXED
packages: [rpc_dart_websocket, rpc_dart]
lens: RPC-20
bench: P-219 — new
budget: probes 5/5, canaries 1/5
commit: yes
release: changelog
severity: S1
---

# Round 615 — the forward that cost a turn

## Target

B-212's first half: whether the three streaming shapes survive a reconnect the
way unary does since round 541, which gave them `only:` by inspection.

## Hypothesis

A streaming responder parked across a reconnect either keeps a stale request feed
or tears down the call that reuses its id.

## Before

```
                 reconnect: second caller   cancelled   guard: second caller
server-stream    answered two               [one]       answered two
client-stream    answered two               [one]       answered two
bidi             answered two               [one]       TIMEOUT, started [one]
```

The hypothesis is REFUTED for all three shapes: each reconnect arm is served and
the parked handler is told. The bidi GUARD failed instead. That is two bidi calls
on one live connection, no reconnect at all.

## Control

Server-stream and client-stream on the same rig. The same two bidi calls with
the handler on the SERVER side of the same socket, always answered. The same two
calls between peers over an in-memory channel pair, answered too
(`.dart_tool/probe/b212_second_bidi_while_first_parks.dart`, both arms).

## Mechanism

For a stream the peer opened, `RpcChannelTransport` broadcasts every frame and
ALSO routes it to the stream's per-stream controller, if one exists by then. The
responder pipeline creates that controller when it binds the call on the opening
frame. From then on it reads requests from the controller and ignores the
broadcast copies.

That is only safe if the pipeline sees the opening frame before the transport
routes the next one. Directly on the transport it does: the broadcast delivery
is scheduled ahead of the next frame's dispatch. `RpcWebSocketCallerTransport`
re-broadcasts `_inner`'s stream through its own async controller, so its stream
survives a reconnect, and that forward costs one microtask. In that turn `_inner`
routed the request with no controller to route to, the broadcast copy arrived
after the bind, and the bound call ignored it. The handler waited for a request
that had already arrived.

The server-side wrapper hands out `_inner.incomingMessages` itself, so the server
was never affected. Client-stream is pipeline-fed and does not read the
controller.

## After

```
bidi             answered two               [one]       answered two
```

`BufferedBroadcastController` takes `sync:`. A live event is delivered from
inside `add`. The buffer is replayed one microtask after the first listen,
never from inside `listen()`, and while a replay is pending, live events queue
behind it. The caller wrapper uses `sync: true`, so its forward adds no turn.

## Canary

`sync: false` in the wrapper: `a peer client gets both bidi requests while the
first call is parked` fails with `TIMEOUT | TIMEOUT | started []`. Not even a
single peer bidi call is served. `buffered_broadcast_sync_test.dart` pins the
controller's own contract, with the async default as its control.

## Gate

`melos run analyze`, `melos run format:check`, `melos run license:check` —
green. `melos run test:unit --no-select`: **red twice, then green twice**
(rpc_dart +1922, websocket +265). The two red runs' failing lines were lost to
the tool's truncated output and are NOT attributed. Each package passed alone
and in narrower concurrent runs, and an identical 15-package run with JSON
reports was green. Recorded as unexplained, not as a known flake.

## Not fixed

B-212's second half, the race against a reconnect factory that returns an
already-open channel, was not driven. And the invariant that broke here is
timing-based: any third-party `IRpcTransport` decorator that re-broadcasts
asynchronously breaks peer bidi the same way. The pipeline cannot tell a
broadcast copy that the controller also got from one it did not.

## Links

Lead `../backlog/B-212-the-streaming-shapes-tail-cleanup-is-unmeasured.md` — narrowed.
Bench `../probes/P-219-the-streaming-shapes-across-a-reconnect.md` — new.
Lens `../lenses/RPC-20-the-window-before-the-first-listener.md` — `applied: [..., 615]`.
Tests `packages/transport/rpc_dart_websocket/test/a_reused_peer_id_streaming_shapes_test.dart`,
`packages/transport/rpc_dart_websocket/test/a_peer_client_gets_every_bidi_request_test.dart`,
`packages/core/rpc_dart/test/core/buffered_broadcast_sync_test.dart`.
