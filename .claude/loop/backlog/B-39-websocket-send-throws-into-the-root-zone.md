---
status: open
round: 358
commit: a0355bfc
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
probe: packages/transport/rpc_dart_websocket/.dart_tool/probe/send_into_a_dead_socket.dart
reason: "the only fix that works is zone-guarding the socket's CONSTRUCTION, which changes where every async error from that channel surfaces — a behaviour decision, and the same one B-35 is waiting on. The call-site fix was measured and does not work"
---

# B-39 — a send racing a raw-socket close throws into the root zone

## Measured

`RpcWebSocketChannel.send` guards on `_closed`, which is OUR flag. The window is
between the raw socket closing and `onDone` being delivered — one event-loop
turn. Channel-level matrix, one variable per row:

```
arm                                 isClosed   closeCode  send
live socket (control)               false      -          returned
our close() first (control)         true       -          returned
peer closed, same turn              false      -          returned
peer closed, +1 turn                false      -          returned
peer closed, +50ms (onDone in)      true       1005       returned
our raw socket, behind the channel  true       1006       returned
our raw socket, same turn, ZONED    false      -          returned, zone saw it
our raw socket, same turn           false      -          ROOT-ZONE CRASH
```

**Only our OWN raw socket, closed in the same turn, reaches it.** A peer close
does not: the sink keeps accepting until it learns. And the crashing row reads
`isClosed false` AND `closeCode null`, so **neither candidate pre-check can see
it** — within one turn nothing observable has changed.

## Why the obvious fix does not work, measured

The refusal is not on the caller's stack:

```
_StreamSinkImpl.add            <- throws Bad state: StreamSink is closed
_WebSocketImpl.add
IOWebSocket.sendBytes
AdapterWebSocketChannel.<fn>
_RootZone.runUnaryGuarded      <- the zone the controller was BUILT in
_StreamController.add
_GuaranteeSink.add
RpcWebSocketChannel.send
```

`WebSocketSink.add` hands the bytes to a StreamController; the real `sendBytes`
runs a microtask later, in whatever zone `AdapterWebSocketChannel` was
constructed in. So:

- **`try { _ws.sink.add(data); } catch (_) {}` changes nothing.** Applied and
  re-run: the crash is identical. Do not re-try this.
- **`runZonedGuarded` around the CALL SITE changes nothing either** — the probe's
  own arm runner does exactly that and the error still reached the root zone.

## What does work, measured

Constructing the `WebSocketChannel` inside `runZonedGuarded` contains it: the
`ZONED` row above returns normally and the construction zone's handler receives
`Bad state: StreamSink is closed`. The construction zone is what decides where
that throw lands.

This is actionable because the library builds the socket itself at its own entry
points — `RpcWebSocketCallerTransport.connect()` and the server's accept path. A
user-supplied `WebSocketChannel` was built in the user's zone and cannot be
reached retroactively.

## Owner decision

A `runZonedGuarded` around construction captures EVERY async error from that
channel's internals, not only send failures — so errors that currently surface
to the application would start being swallowed or rerouted. That is the same
objection B-35 records for `package:http2`, and the same decision:

1. leave it, and document that an application closing the raw socket it handed
   us can crash the isolate;
2. zone-guard the sockets the library constructs, and route contained errors
   somewhere deliberate (the channel's `incoming` as an advisory error, per
   round 353's `IRpcAdvisoryChannelError`, or a log);
3. report it upstream to `package:web_socket_channel` — a sink that refuses an
   add should reject a future, not throw into a foreign zone.

Round 358 recommends (2) scoped to the library's own entry points PLUS (1)'s
documentation for user-supplied sockets, but it is a behaviour change and the
owner's call — and (2) is worth pairing with a decision on B-35, which is the
identical shape one dependency over.

## Reachability

The library's own teardown paths are SAFE: `RpcWebSocketServer` closes endpoints,
which reach `RpcWebSocketChannel.close()` and set `_closed` first;
`closeForProtocolError` sets it first too. What reaches this is an application
holding the raw `WebSocket` it passed to `RpcWebSocketChannel` and closing that
directly while a response is in flight — which is how round 353's fixture hit it
by accident.

## Guarded by

`packages/transport/rpc_dart_websocket/test/send_after_raw_socket_close_test.dart`
— pins that the throw still happens and still lands in the construction zone, so
the day `package:web_socket_channel` changes, this lead closes. Its three GUARDs
pin what is NOT broken: a live send, a send after our own close(), and a peer
close.
