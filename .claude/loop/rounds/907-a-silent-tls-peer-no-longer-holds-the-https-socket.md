---
round: 907
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-28
bench: P-359 — new
commit: yes
severity: S1 — "memory or CPU a peer or ordinary use can grow without bound"
release: changelog
---

# Round 907 — a silent TLS peer no longer holds the https caller's socket

## Target

B-314, the http half of round 906's wss fix. P-353 measured it: an https call
to a peer that accepts TCP and never answers TLS ended at its 1 s deadline and
the socket stayed OPEN at 16 s. The lead predicted "the http half needs more
than the factory".

## Hypothesis

The factory alone does not fix the http caller, because nothing ever cancels
the connection task: `package:http`'s `IOClient.send` attaches the
`AbortableRequest` trigger only AFTER its `openUrl` returns, and the deadline
abandons the await rather than the work. A pending connection can only be
released by `HttpClient.connectionTimeout` (or closing the client), so the
owned client needs a connect bound in addition to the factory. Fails if the
https arm's socket stays open past the connect timeout, or if it closes
without the factory (then the factory is not load-bearing and the timeout did
the work alone).

## Before

P-353, 1 s deadline, a listener that accepts TCP and never writes:

```
arm=http   returned=1033 ms (1 s deadline)  socket=closed at 1034 ms
arm=https  returned=1003 ms (1 s deadline)  socket=OPEN at 16006 ms
```

## Mechanism

Two stages, two owners. Once the request is on the wire, `ioRequest.abort()`
closes the socket — the plaintext arm closes at its deadline because loopback
`openUrl` returns before the deadline fires. While the connection is still
being established there is no request object; `dart:io` exposes no per-request
connect cancel, so the only release is the client-level `connectionTimeout`
firing its timer, which cancels the connection task. With `dart:io`'s own
secure connect that cancel stops at the TCP stage (round 906's mechanism), so
the timeout alone leaves the socket open; with the task built by
`RpcSecureSocket.startConnect` the same cancel closes the socket in either
stage.

## After

`packages/transport/rpc_dart_http/test/a_silent_tls_peer_drops_the_https_socket_test.dart`,
connect timeout 5 s, release at 1 s, close measured at the acceptor:

```
WITNESS  https, owned client (factory + timeout)      socket closed by 5.3 s
CONTROL  http,  owned client                          socket closed at ~1 s
CANARY   https, caller IOClient, timeout, NO factory   socket OPEN past 9 s
```

All three arms as predicted. The fix: the owned client (new
`owned_http_client.dart`, conditional export — IO vs web) sets
`HttpClient.connectionFactory` to `RpcSecureSocket.startConnect` for https and
`Socket.startConnect` otherwise, and a new `connectTimeout` constructor knob
(default 30 s, matching `RpcClientConnection`; null for none) becomes the
client's `connectionTimeout`. A caller-supplied client is untouched.

Full package suite: 260 passed. `dart analyze`: clean. Web smoke
(`--platform chrome test/web_smoke_test.dart`): green — the stub is the web
build of the owned client.

## Canary

The CANARY arm is the load-bearing half: a caller-supplied `IOClient` with the
SAME 5 s `connectionTimeout` but WITHOUT the connection factory. dart:io's own
secure connect cancels only the TCP stage, and the arm's socket stayed OPEN
past 9 s — so the witness arm's close is the factory's doing, not the
timeout's. Both arms ended the call the same way (release at 1 s, handshake
never answered).

## Gate

`fvm dart test` in `packages/transport/rpc_dart_http` (260 passed, including
the new witness) and `fvm dart analyze packages/transport/rpc_dart_http`
(no issues). Web: `fvm dart test --platform chrome test/web_smoke_test.dart`.
The full-repo `melos run test` was not run; the change touches one package.

## Siblings

- member: caller — fixed in this round, `a_silent_tls_peer_drops_the_https_socket_test.dart`
- member: responder — n/a — the server's side of a silent handshake (a peer that never sends ClientHello holding an accepted socket) is a different defect, open as B-316
- member: channel — n/a — in-process, no TLS
- member: http — fixed in this round
- member: http2 — fixed in rounds 904/905, `a_silent_tls_peer_ends_the_connect_test.dart` (P-353 promoted) and the per-attempt cancellation token
- member: websocket — fixed in round 906, P-356
- member: isolate — n/a — in-process, no TLS
- member: wasm — n/a — no TLS of its own

## Not fixed

- The socket is freed at `connectTimeout`, not at the call's deadline. No
  earlier release exists: `package:http` attaches the abort only after
  `openUrl` returns, and `dart:io` has no per-request connect cancel. The
  websocket caller gets prompt closure by owning an `HttpClient` per
  connection; here the pool is shared across calls, and the trade is stated on
  the constructor rather than hidden.
- A proxied https connection is tunnelled by `HttpClient` itself, and the
  handshake over the CONNECT tunnel runs on dart:io's own stack — the same
  accepted limitation as the websocket sibling, unmeasured.
- A caller-supplied `http.Client` keeps dart:io's default behavior unless the
  caller sets `connectionFactory` and `connectionTimeout` themselves; the
  constructor dartdoc and README say how.

## Links

- Closes B-314.
- P-359, promoted to the witness test above.
