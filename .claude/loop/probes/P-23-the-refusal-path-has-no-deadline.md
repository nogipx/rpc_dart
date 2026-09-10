---
file: packages/transport/rpc_dart_http/.dart_tool/probe/refusal_path_has_no_deadline.dart
round: 272
commit: eac7dde2
paths: [packages/transport/rpc_dart_http/lib/**]
status: valid
---

# P-23 — is the refusal path bounded by anything?

Opens N sockets that promise a 100000-byte body, send five bytes and then HOLD
the connection — an ordinary slowloris. Reports how many were answered inside a
window six times the configured `bodyReadTimeout`, what the server's own
counters say, and whether an ordinary call still works.

Point it at another rejection exit by changing the request line: `GET` for the
405 branch, a path over `maxMethodPathLength` for the 400 branch.

## Measures

Sockets ANSWERED inside the window, counted at the client on the first byte the
server sends (or on the close). Not RSS: the drain retains nothing, so the
damage is a read loop and a file descriptor, and neither shows up in memory.

## Control

One header. `content-type: application/grpc` reaches `readBody()`, which the
timeout has always covered; `text/plain` reaches `_reject`, which it did not.
Same sockets, same bytes, same server.

```
arm      content-type       answered in 3s  still draining  pendingRequests
accept   application/grpc   16 of 16 (408)  0               0     <- both
refuse   text/plain          0 of 16        16              0     <- before
refuse   text/plain         16 of 16        0               0     <- after
```

> **`pendingRequests` reading 0 in every row is the finding, not a null result.**
> A refusal happens before the stream is registered, so the only counter this
> transport exposes cannot see the attack at all — a health check would have
> called the server idle while it held sixteen open reads. When an arm shows a
> counter unmoved, ask whether the counter is downstream of the thing you are
> attacking.

After the fix the `refuse` arm settles by CLOSE rather than by a status line:
dart:io cannot flush a response on a request whose body was not consumed. That
is the intended answer to a slowloris and the reason the accept arm is kept as
the control — it still answers 408, so "the server settled everything" cannot be
mistaken for "the server stopped talking".
