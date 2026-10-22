---
round: 905
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: P-355 — new
commit: yes
severity: S2 — "a bounded leak"
release: changelog
---

# Round 905 — a dispose ends the http2 connect

## Target

The owner asked for imperfections of abstractions, which is RPC-25's shape:
one contract, several copies, one that drifted. The contract here is the
transport factory `RpcClientConnection` calls with a fresh
`RpcCancellationToken` per attempt, cancelled on `dispose()`, `disconnect()`
and past its `connectTimeout`. Listing every async transport open (the class,
counted first): websocket `connect` and socket `connectRpcSocket` take the
token (rounds 890, 897); http2 `connect` / `secureConnect` take none;
isolate `spawn` takes none (B-315); http and channel have no async open.

B-310 (rank 3) named the http2 half and rested on reading the code. B-314
(rank 2) needs a dart:io capability that does not exist (round 904) and is
not one round. The bench is new: P-342 measured a different stage and is
stale.

## Hypothesis

`RpcClientConnection.dispose()` during an http2 attempt that is still inside
its factory (a TLS handshake or a proxy CONNECT the peer never answers)
leaves the socket open until the transport's own `connectTimeout`. Fails if
the listener sees the close within the time the h2c control takes.

## Before

```
dispose 200 ms into the attempt, listener accepts TCP and never writes
arm=h2c    dispose=6 ms  socket=closed 8 ms after dispose
arm=h2     dispose=0 ms  socket=OPEN 15003 ms after dispose
arm=proxy  dispose=0 ms  socket=OPEN 15002 ms after dispose
```

Probe: `packages/test/rpc_dart_conformance/.dart_tool/probe/r905_dispose_mid_connect/probe.dart`

## Mechanism

The http2 open takes no token, so the token `RpcClientConnection` cancels
reaches nothing; it can only stop waiting and close a transport the factory
delivers, and this factory delivers only at its own 30 s timeout.

## After

```
PASS=1 (the factory passes its token)
arm=h2c    dispose=10 ms  socket=closed 13 ms after dispose
arm=h2     dispose=1 ms   socket=closed 2 ms after dispose
arm=proxy  dispose=1 ms   socket=closed 6 ms after dispose
```

`connect` and `secureConnect` take `cancellationToken`. One `_AttemptGuard`
per attempt holds what the current stage has open (the TCP `ConnectionTask`,
then the socket, then the pipe) and closes it on cancel until the connection
is delivered; the TCP stage moved to `startConnect` so it can be stopped, the
socket caller's idiom. The await races the token, because closing the
RawSocket does not end a pending `RawSecureSocket.secure` (canary A below).
A cancel fails the connect with `RpcCancelledException`, as on websocket and
socket.

## Canary

Witness `packages/transport/rpc_dart_http2/test/a_cancel_ends_an_http2_connect_test.dart`,
three halves, three canaries, each failing differently:

- race off (`cancellationToken != null && 1 < 0`): TLS stage "threw
  TestFailure:<the connect is still pending 5 s after the cancel>"; proxy
  stage "threw RpcStatusException(14): HTTP/2 connect failed:
  SocketException: Proxy closed during CONNECT", not `RpcCancelledException`.
- release off (`if (1 < 0) _release?.call();`): both stages "the socket is
  still open 5 s after the cancel".
- delivered check off (`_delivered && 1 < 0`): "a cancel after the connect
  leaves the connection working" failed with "RpcStatusException(14):
  Transport is closed: the peer went away".

Restored: 3/3 green.

## Gate

`melos run analyze` green; `melos run test:unit:quiet --no-select` SUCCESS,
17 packages, rpc_dart_http2 +349 (melos printed its usual "Can't load Kernel
binary" line first); `melos run format:check` SUCCESS; `melos run
license:check` compliant; `melos run check:skills` clean (the skill's
`errors-and-resilience.md` names the callers that take the token).

## Siblings

- http2: fixed here — P-355, 15003 / 15002 ms -> 2 / 6 ms.
- websocket: clean — takes the token; `a_cancelled_connect_closes_its_socket_test.dart` green in this round's gate (+309).
- channel: n/a — built synchronously over an existing channel; no async open to cancel.
- http: n/a — the constructor opens nothing; every call is its own request, ended by the call's own context.
- isolate: deferred — B-315; `spawn` takes no token, not measured.
- wasm: n/a — an in-process runtime, no connect stage.
- caller: fixed here — the change is the http2 caller's open.
- responder: n/a — a responder opens no outbound connection; the factory contract is the caller's.

## Not fixed

B-315, the isolate spawn, read from the code and not measured; its wait is on
the process's own worker and bounded by `startupTimeout`. B-314 stays as round
904 left it. The black-hole TCP stage (a SYN nobody answers) is now
`startConnect` + `cancel()` as on the socket caller, where round 897 measured
it; it was not re-measured here.

## Links

RPC-25, P-355, B-310 (closed), B-314, B-315, rounds 890 and 897 (the siblings
that took the token), round 904 (`_secureH2`).
