---
round: 747
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-13
bench: P-251 — new
commit: yes
release: changelog
---

# Round 747 — a given channel that never connects

## Target

B-268, filed by round 746 from its control arm: a websocket transport built
with the constructor over `IOWebSocketChannel.connect(uri)`, with no server,
ended the process with an uncaught `WebSocketChannelException`. The README
documents the constructor for a channel the caller builds.

## Hypothesis

The transport leaves an error from the channel unobserved.

## Before

P-251:

```
  rpc    health right after construction: healthy
         health after 2 s: closed isClosed=true
         uncaught errors 1 [WebSocketChannelException]
  bare   stream error;  uncaught errors 1 [WebSocketChannelException]
  ready  stream error;  ready failed;  uncaught errors 0
```

## Mechanism

`bare` reproduces it without rpc_dart. web_socket_channel completes `ready`
with the connect error, and an unobserved `ready` is an uncaught error. The
same failure also reaches the stream, which is how the transport closes
itself. Nothing in the transport ever listened to `ready`.

## Fix

`_attach`, which every channel passes through (the constructor's and a
reconnect factory's), observes `ws.ready` with a `catchError`
(`d4e8de6c`).

## After

The witness passes: the transport closes and nothing is uncaught.

## Canary

The Before run of the same witness, on the code without the line:

```
  WITNESS a channel whose connect fails closes the transport, quietly [E]
    WebSocketChannelException: OS Error: Network is down, errno = 50
```

## The verdict questions

1. Yes: the documented constructor, a server that is down.
2. Yes: `ready`, the same channel with `ready` observed, has no error.
3. In the zone's uncaught-error handler, and in package:test's.
4. n/a.
5. Quoted.
6. One mechanism.
7. Not a trade.
8. B-268's other half stays open.
A1. A server that is down when the client starts.
A2. An uncaught error, which ends an app's root isolate.
L1. n/a.

## Gate

`analyze`, websocket suite 293. `test:web`: the websocket web smoke test
passed; the chrome step failed loading `echo_worker_test.dart` in
rpc_dart_isolate, which passes alone, the cold-start failure the script's
own comment describes. Two of the last three gate runs failed there.

## Not fixed

B-268's first half: `health()` says healthy right after construction, before
the channel is ready, so `RpcClientConnection` reports online over a channel
that may never connect.

## Links

Lens `../lenses/RPC-13-unhandled-async-error.md` — `applied: [..., 747]`.
New bench `../probes/P-251-a-given-channel-that-never-connects.md`.
Lead `../backlog/B-268-a-constructed-websocket-transport-reports-online-early.md`.
