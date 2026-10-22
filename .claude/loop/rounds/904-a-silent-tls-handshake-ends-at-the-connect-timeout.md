---
round: 904
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-28
bench: P-353 — new
commit: yes
severity: S1 — "a call, connection or shutdown that hangs with no bound"
release: changelog
---

# Round 904 — a silent tls handshake ends at the connect timeout

## Target

B-309, the top measured lead after the curate pass (66cabcb3); the one ranked
above it awaits the owner. B-313 (rank 2) was weighed first and dismissed on current
code: the owner's 18bf8c7b added the responder's `compressionEnabled`, off by
default; its witness re-run green on HEAD with its control arm, so it closes
here. RPC-27's unwalked containers in core were weighed too:
`RpcBufferedBroadcastController` is bounded in bytes at all 8 construction
sites (each passes `sizeOf: (m) => m.bufferedBytes`, which weighs metadata),
so not a target.

B-309 rested on one P-342 run with dispose. The http2 code comment said
"Under TLS it covers the handshake too"; the SDK source says otherwise. Same
class across the transport group: every caller that opens TLS (http2 direct,
http2 via proxy, websocket wss, http https). The proxy path already bounded its
handshake on a RawSocket; the direct path did not. P-342 is stale and measured
dispose, so a new bench, P-353.

## Hypothesis

`RpcHttp2CallerTransport.secureConnect` to a peer that accepts TCP and never
answers TLS returns at `connectTimeout` and closes the socket. Fails if the
connect is still pending well past the timeout, or the listener never sees a
close.

## Before

```
connectTimeout 1 s, listener accepts TCP and never writes
arm=h2c  returned=24 ms               socket=closed at 1036 ms
arm=h2   returned=PENDING at 8000 ms  socket=OPEN at 23007 ms
arm=ws   returned=1029 ms             socket=closed at 1029 ms
arm=wss  returned=1003 ms             socket=OPEN at 16006 ms
arm=http   returned=1033 ms (1 s deadline)  socket=closed at 1034 ms
arm=https  returned=1003 ms (1 s deadline)  socket=OPEN at 16006 ms
```

Probe: `packages/test/rpc_dart_conformance/.dart_tool/probe/r904_tls_silent/probe.dart`

The close is read at the listener, so a half-close would read the same
(L-21); the fix calls `RawSocket.close()`, which closes both directions, and
the release canary below shows the listener sees no close without it.

## Mechanism

`SecureSocket.connect(timeout:)` passes the timeout to `RawSocket.connect`
and then awaits `secure()` with no bound; once the handshake owns the socket,
nothing the caller holds can close it. `startConnect().cancel()` ends only
the TCP phase too, which is why HttpClient (wss, https) stops waiting yet
leaves the socket open.

## After

```
arm=h2c  returned=24 ms    socket=closed at 1024 ms
arm=h2   returned=1011 ms  UNAVAILABLE "TLS handshake with 127.0.0.1:55562 did not finish within 0:00:01.000000"  socket=closed at 1012 ms
```

The direct TLS path now runs like the proxy path: `RawSocket.connect`,
`RawSecureSocket.secure(...).timeout(connectTimeout)` closing the RawSocket
on timeout, ALPN checked, then `RawSocketPipe`. One helper, `_secureH2`,
serves both paths; `_requireH2` is gone. Throughput of the byte path (P-354,
loopback TLS, 128 MiB, median of 5), asked of the owner before the change:

```
dir=up    socket 138 MiB/s (129-143)   pipe 152 MiB/s (137-157)
dir=down  socket 150 MiB/s (144-158)   pipe 146 MiB/s (132-155)
```

Within the spread; no speed traded.

## Canary

Witness `packages/transport/rpc_dart_http2/test/a_silent_tls_peer_ends_the_connect_test.dart`.
Two halves, two canaries, each failing differently:

- bound off (`timeout == null || 1 > 0`): failed with "threw
  TestFailure:<secureConnect still pending at 10 s>".
- release off (`if (1 < 0) await raw.close();` on timeout): failed with "the
  handshake socket is still open at 10 s".

Restored: green.

## Gate

`melos run analyze` green (23 packages + wasm); `melos run test:unit:quiet
--no-select` SUCCESS, 17 packages, rpc_dart_http2 +346 (melos printed its
usual "Can't load Kernel binary" line before running); `melos run
format:check` SUCCESS; `melos run license:check` compliant. The full
rpc_dart_http2 suite also ran once on its own before the gate: +346, including
`tls_through_a_proxy_test` (direct and proxied TLS reach the same outcome).

## Siblings

- http2: fixed here — P-353 h2 arm, pending at 8 s / open at 23 s -> 1011 ms / closed at 1012 ms.
- websocket: deferred — B-314; P-353 wss arm returns at 1003 ms but its socket is open at 16006 ms (ws control closed at 1029 ms).
- http: deferred — B-314; P-353 https arm ends at its 1 s deadline, socket open at 16006 ms (http control closed at 1034 ms).
- channel: n/a — in-memory, no TLS stage.
- isolate: n/a — SendPort messages, no socket.
- wasm: n/a — an in-process runtime, no socket.
- caller: fixed here — the change is the http2 caller's open path; P-353 h2 arm above.
- responder: clean — the server half of the same stage, a client silent after TCP on a TLS server, is `a_silent_tls_socket_is_dropped_test.dart`, green in this round's rpc_dart_http2 run (+346).

## Not fixed

wss and https (B-314): both go through dart:io HttpClient, which needs a
`Socket` it can own, and a `RawSecureSocket` cannot be turned into one
through public API. Their calls end on time; the leak is one socket per
attempt for as long as the peer holds it. A Socket implementation over
`RawSecureSocket` is more than one round. rpc_dart_socket opens no TLS.

## Links

RPC-28, P-353, P-354, B-309 (closed), B-313 (closed), B-314, P-342 (the
earlier run B-309 rested on), round 773 (the sweep that missed the TLS
stage), L-21, L-25.
