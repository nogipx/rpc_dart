---
round: 831
verdict: CLEAN
packages: [rpc_dart_websocket]
lens: RPC-22
bench: none — one probe, below; a CLEAN with a control
commit: yes
severity: S3
release: none
---

# Round 831 — a failed TLS handshake does not stop the websocket server

## Target

Network-audit KV-G-03: "a TLS handshake error must not end the server's
listen loop". Round 812 covered descriptor exhaustion and left TLS out.
`RpcHttpServer` binds plain sockets only; the websocket server serves
whatever `HttpServer` the application hands it, `bindSecure` included.

## Hypothesis

A handshake failure surfaces as an error on the `HttpServer` stream that
`rpcWebSocketConnections` filters, ends the subscription or reaches the
zone, and the server stops accepting.

## Before

```
r831_tls_handshake_errors.dart 0 (control): honest wss call ok, 0 errors, nothing uncaught
```

## Mechanism

n/a (CLEAN).

## After

```
r831_tls_handshake_errors.dart 10 (5 plaintext, 5 cut ClientHellos):
  honest wss call ok, 0 connection errors reported, nothing uncaught
```

## Canary

n/a; the control is the bad connections' absence, and the honest call goes
through the same TLS listener after them.

## The verdict questions

1. Only the failed handshakes differ.
2. No difference: CLEAN.
3. At the server: `onConnectionError` and the zone; at the caller: the
   honest call.
4. Ten failures of two kinds.
5. n/a (CLEAN).
6. n/a.
7. CLEAN with a control.
8. none.
9. none.
10. No code changed.
A1. n/a. A2. n/a. L1. n/a.

## Gate

No code changed; the probe is outside the tree.

## Siblings

No code changed. `RpcHttpServer` has no TLS listener; http2's TLS server is
low priority and was not measured.

## Not fixed

none.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`. Negative
`../checked/C-80-failed-tls-handshakes-leave-the-websocket-server-serving.md`.
Round `812-both-servers-survive-descriptor-exhaustion.md`.
