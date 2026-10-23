---
round: 906
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-28
bench: P-356 — new
commit: yes
severity: S1 — "memory or CPU a peer or ordinary use can grow without bound"
release: changelog
---

# Round 906 — a silent tls peer no longer leaks a wss socket per attempt

## Target

The owner asked for imperfections of abstractions. Weighed first and
dismissed on records and current code: the decode-failure copies on caller
and responder (rounds 626, 631, 817, 854, 861 cover them), the `IRpcServer`
lifecycle and drain (rounds 403, 414, 418, 421, 454, 531, 822, 823), and the
four core interceptors (rate limiter metering read in full; rounds 351, 420,
501, 669 on the others). B-315 (isolate spawn, no token) is bounded by
`startupTimeout`, a smaller stake.

Taken instead: B-314, re-read against its stake. Round 904 measured one wss
attempt holding its socket; it did not measure a reconnect loop, which is how
`RpcClientConnection` meets a peer like that. Websocket is the owner's second
priority. No bench covered the loop, so P-356 is new.

## Hypothesis

A reconnect loop of the websocket caller against a peer that accepts TCP and
never answers TLS adds one open socket per attempt, and `dispose()` releases
none. Fails if the wss arm holds no more sockets than the ws control.

## Before

```
P-356, connectTimeout 500 ms, fixed backoff 100 ms, own sockets by lsof
arm=ws   accepted=26  t=5s open=1  t=10s open=1   t=15s open=1   after-dispose=0
arm=wss  accepted=25  t=5s open=9  t=10s open=17  t=15s open=25  after-dispose=25
```

Probe: `packages/test/rpc_dart_conformance/.dart_tool/probe/r906_reconnect_tls_leak/probe.dart`

## Mechanism

`SecureSocket.startConnect` hands the TLS task the raw TCP task's cancel, and
`SecureSocket.secure` detaches the plain socket (`_detachRaw` sets its `_raw`
to null), so nothing can close a socket in its handshake. HttpClient's
`connectionTimeout` and `close(force: true)` cancel the task and stop
waiting; the socket stays open for as long as the peer holds it.

## After

```
arm=ws   accepted=25  t=5s open=1  t=10s open=1  t=15s open=0  after-dispose=0
arm=wss  accepted=26  t=5s open=1  t=10s open=1  t=15s open=0  after-dispose=0
```

`RpcSecureSocket.startConnect` (`package:rpc_dart/transport_io.dart`, the
owner's choice of home) connects a `RawSocket`, runs `RawSecureSocket.secure`
on it, and delivers a `SecureSocket` over the result; its cancel closes the
socket in either stage and fails the task at once. The websocket caller's
`HttpClient` gets it through `connectionFactory` on both of its open paths.

The adapter's `addStream` pauses its source while bytes wait for the socket.
P-357, a TLS peer that never reads, bytes pulled from an endless source in
3 s:

```
arm=io   832 KiB     (dart:io SecureSocket)
arm=rpc  832 KiB     (RpcSecureSocket)
```

wss speed, asked of the owner before the change (P-358, loopback, median of
5, arms interleaved):

```
4 MiB echo      io 225.1 / 243.3 MiB/s    rpc 242.2 / 243.3 MiB/s
100 B round trip io 239.3 / 219.2 us      rpc 226.5 / 224.7 us
```

Within the spread of the io arm against itself; no speed traded.

## Canary

Witnesses: `packages/transport/rpc_dart_websocket/test/a_silent_tls_peer_releases_the_wss_socket_test.dart`
and `packages/core/rpc_dart/test/integration/secure_socket_connect_test.dart`.

- factory off on the default path (`if (1 < 0) own.connectionFactory = ...`):
  wss witness failed with "the handshake socket is still open at 10 s".
- cancel's close off (`socket != null && 1 < 0`): the wss witness as above,
  and the core one with "the handshake socket is still open".
- cancel race off (`if (1 < 0)` before the cancel arm of `Future.any`):
  "threw TestFailure:<the task is still pending after the cancel>".
- destroy's stop of `addStream` off (`if (1 < 0) _stopStreaming?.call()`):
  "addStream did not end with the socket". This half was found by the test:
  the first version kept draining the source after destroy, a microtask loop
  that starved the test's own timeout, and the deaf-peer test now yields per
  chunk so that failure is a message, not a hang.

Restored: 6/6 green.

## Gate

`melos run analyze` green; `melos run test:unit:quiet --no-select` SUCCESS,
17 packages (rpc_dart +2417, rpc_dart_websocket +311; melos printed its usual
"Can't load Kernel binary" line first); `melos run format:check` SUCCESS;
`melos run license:check` compliant; `melos run api:check` matches after
`api:update` (two lines: `RpcSecureSocket` in `transport_io.dart`);
`melos run check:skills` clean; `melos run test:web --no-select` all suites
passed.

## Siblings

- websocket: fixed here — P-356 wss, 25 open after 15 s -> at most 1, 0 after dispose.
- http: deferred — B-314; P-353 https arm, socket open 16006 ms after a 1 s deadline. Its default client has no connect bound to cancel with, and a user's client cannot take a factory without losing its context.
- http2: clean — round 904 put its TLS on a RawSocket closed at the timeout; P-353 h2 closed at 1012 ms, its witness green in this gate (+349).
- channel: n/a — in-memory, no TLS.
- isolate: n/a — SendPort messages, no socket.
- wasm: n/a — an in-process runtime, no socket.
- caller: fixed here — the websocket caller's open.
- responder: deferred — B-316; the server's side of the same stage (a client that never sends a ClientHello to `HttpServer.bindSecure`) is unmeasured for websocket and http.

## Not fixed

B-314's http half, for the reasons in its sibling line. B-316, the server
side. A proxied wss connect: HttpClient tunnels through the proxy and calls
`SecureSocket.secure` itself, so a silent target behind a proxy still keeps
its tunnel socket. http2's `RawSocketPipe` duplicates part of the new adapter
and could move onto `RpcSecureSocket`; a refactor, no defect.

The wss end-to-end test runs both branches: where the default context trusts
the test certificate it carries a call and a 3 MiB message, and on macOS,
which does not consult it, it checks that the wss connect refuses the
certificate exactly when dart:io's own connect does. This round's runs were on
macOS, so the data path was exercised by the core test (32 MiB echo, a
WebSocket upgrade with a 4 MiB message), not through the websocket caller.

## Links

RPC-28, P-356, P-357, P-358, B-314, B-316, P-353, rounds 904 and 905, L-21.
