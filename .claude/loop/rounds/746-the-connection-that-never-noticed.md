---
round: 746
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket, rpc_dart_http2]
lens: RPC-19
bench: P-250 — new
commit: yes
release: changelog
severity: S1
---

# Round 746 — the connection that never noticed

## Target

Whether a process exits on its own once a server and a client have made calls
and been closed. Rounds 323 and 577 measured that only for a failed isolate
spawn. The http2 and websocket transports, their keepalives and
`RpcClientConnection` had never been driven to the end of `main`.

## Hypothesis

A timer or socket survives `close()` and holds the process open after `main`
returns.

## Before

P-249, exit latency after `main` returns:

```
  rpc_dart_http2      plain   exited 0, 15 ms
  rpc_dart_http2      ping    exited 0, 12 ms
  rpc_dart_http2      leak    HUNG            (control: server left running)
  rpc_dart_websocket  plain   exited 0, 14 ms
  rpc_dart_websocket  ping    exited 0, 19 ms
  rpc_dart_websocket  conn    exited 0, 10 ms
  rpc_dart_websocket  drop    exited 0, 11 ms
  rpc_dart_websocket  leak    HUNG            (control)
```

The hypothesis is refuted. The `drop` arm showed something else: 1.5 s after
the server stopped, the connection still said `RpcClientOnline`. P-250
followed it through a restart on the same port:

```
  websocket, RpcClientConnection, default backoff
    server.stop() 4 ms, http.close(force) 7 ms
    t=511..2018 ms  isClosed=false health=degraded conn=RpcClientOnline
    after stop:     RpcNoConnectionException (transport disconnected)
    server back at 2022 ms
    t=5024 ms       conn=RpcClientOnline
    after restart:  RpcNoConnectionException

  http2, the same
    t=2008 ms conn=RpcClientOnline;  after restart: RpcStatusException

  control, websocket transport built without a reconnect factory
    state -> RpcClientOffline, RpcClientConnecting   (at once)
```

Behind `RpcClientConnection`, which both READMEs recommend for automatic
reconnect, a server restart left every call failing for good on both network
transports.

## Mechanism

`RpcClientConnection` learns of a drop from its transport's message stream:
its end, or an error that is not about one frame. A transport from
`connect()` has a reconnect factory, so on a drop it stays open with
`incomingMessages` open and silent: `_disconnected = true` and wait for
`reconnect()`. One signal, two readers: to the transport an open stream means
"disconnected, recoverable"; to the connection it means "online". Neither
drove the reconnect. http2 also had no signal for a socket's end at all;
package:http2 reports none, and only keepalive marked the transport
disconnected.

## Fix

The first attempt put `RpcNoConnectionException` on `incomingMessages`. The
probe passed, then `websocket_reconnect_test` failed: it listens to that
stream with no `onError`, and the error arrived uncaught. Any user listening
the same way would have lost the isolate on a server restart (RPC-13). That
commit was taken back before it left the machine.

What shipped:

- `rpc_dart` (`935f1290`): `IRpcConnectionLossReporting` with a broadcast
  `connectionLost` stream. The proxy listens when its transport has it and
  treats an event as the end; an event from a transport it has already
  replaced is ignored.
- `rpc_dart_websocket` (`f8dd6a88`): emits on a socket drop with a factory.
- `rpc_dart_http2` (`8d6a35a2`): `guardHttp2HeaderBlock` gains `onEnd`.
  Connections are numbered through `_DrainSignal`, so the end of one that
  `reconnect()` retired is not a loss. Socket end and keepalive share one
  `_connectionLost(number)`, which marks the transport disconnected and emits.

## After

```
  websocket  stop -> Offline, Connecting x3; restart -> Online; call ok in 8 ms
  http2      stop -> Offline, Connecting; restart -> Online; call ok in 3 ms
```

## Canary

- websocket emit removed: the witness fails with "the server stopped and the
  connection still reports RpcClientOnline"; the guard times out.
- http2 emit removed: the same witness message; the guard reads
  `Expected: [RpcNoConnectionException], Actual: []` in its first form and
  `losses 0` in its final one.
- proxy listener removed: the core witness times out.
- proxy identity check and old-subscription cancel removed: the core guard
  sees a second Offline.

## The verdict questions

1. Yes: the README's own setup, a real server restart on the same port.
2. Yes: the `nofactory` control goes Offline at once over the same socket
   events.
3. In the connection's state stream and in a call after the restart.
4. Not a performance claim.
5. Quoted.
6. One mechanism, two transports, each with its own witness.
7. Not a trade. A new public interface: a minor release of `rpc_dart`, and
   the transports need its floor raised (`bump:rpc_dart`).
8. B-268, B-269.
A1. The default policy and backoff; 50-200 ms backoff in the tests.
A2. Recovery after a peer restart.
L1. n/a.

## Gate

`analyze`, `test:unit`, `format:check`, `license:check`, `check:skills`
(the skill describes the new interface). Package suites: websocket 292,
http2 308. `test:web`: the first run failed loading
`echo_worker_test.dart` in the isolate package before any test ran; the
second run passed everything. Not a code path this round touched.

## Not fixed

- B-268: a websocket transport built on an unconnected channel reports online
  and then crashes the process on the connect error.
- B-269: http2 reports online before the server's SETTINGS.
- A transport decorator that does not forward `IRpcConnectionLossReporting`
  hides it again (RPC-04); documented in the skill, not enforced.

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` — `applied: [..., 746]`.
New bench `../probes/P-250-a-client-connection-across-a-server-restart.md`;
the exit sweep that led to it is `../probes/P-249-the-process-exits-after-close.md`.
Round `234-the-reconnect-nobody-drives.md` — the same title, a different drop.
