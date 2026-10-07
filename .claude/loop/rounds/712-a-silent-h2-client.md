---
round: 712
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-13
bench: none — `.dart_tool/probe/audit_h2/h2c_silent.dart`, `tls_only.dart`, `tls_detach.dart`, `tls_detach2.dart`, `tls_firstbyte.dart`
commit: yes
release: changelog
---

# Round 712 — a silent h2 client

## Target

B-260: one TCP client that sends nothing kills an h2c server at default
settings, and under TLS is held open for good.

## Hypothesis

The preface deadline and the first keepalive tick share a duration (30 s) and
fire in one turn. The deadline destroys the socket; the keepalive's
`connection.ping()` registers a completer, throws synchronously on the write,
and package:http2 later fails that orphaned completer in the root zone.

## Before

```
h2c, preface 1 s, ping 1 s, one silent socket:
Unhandled exception: HTTP/2 error: ... forcefully terminated. (errorCode: 10)
TLS, same settings: STILL OPEN after 8s
```

Controls (agent): preface alone or keepalive alone does not crash.

## Mechanism

As hypothesised for the crash. For TLS: `SecureServerSocket` hands a socket
over only after its handshake, so the preface deadline never starts. A deadline
on `SecureSocket.secureServer` does not help either: measured, once it owns the
socket, `destroy()` on the original no longer closes it, with or without a
paused subscription (`tls_detach.dart`: STILL OPEN). A `RawSocket` stays
closable (`tls_detach2.dart`), but the server needs a `Socket`.

## Fix

- `startHttp2Keepalive` pings inside its own error zone, so the orphaned
  completer's error lands there. Covers the caller half too.
- The TLS server binds a plain `ServerSocket`, waits for the client's first
  bytes under `prefaceTimeout` while the socket is still its own, then runs
  `SecureSocket.secureServer` with them as `bufferedData`. Sockets still
  waiting are destroyed by `stop()`.

## After

```
h2c silent socket: closed by server, process alive
tls silent socket: closed by server
```

## Canary

The ping reverted to the bare call: the new same-turn test fails with the
unhandled error, three times. The server file stashed: the TLS witness fails.

## The verdict questions

1. Yes. 2. Yes, defaults. 3. Yes. 4. Not zero. 5. Quoted. 6. Two causes, two
tests. 7. Not a trade. 8. None changed.

## Gate

`analyze`, `format:check`, the full rpc_dart_http2 suite (297 + 2).

## Not fixed

- A TLS client that sends part of a ClientHello and stalls is still held: the
  handshake cannot be bounded once it owns the socket.
- The caller's proxy path bounds its TLS handshake with `rawSocket.destroy()`
  after `SecureSocket.secure`, the same pattern measured above not to close the
  socket. Unmeasured on that path.

## Links

Lead `../backlog/B-260-a-silent-h2-client-kills-the-server.md` closed.
Lens `../lenses/RPC-13-unhandled-async-error.md` -- `applied: [..., 712]`.
