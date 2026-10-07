---
status: closed (round 712)
round: 712
commit: 45ee7b15
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart]
probe: .dart_tool/probe/audit_h2/h2c_silent.dart
reason: "measured — found by the http2 audit after round 710"
---

# B-260 — a silent h2 client kills the server

## Seen

`RpcHttp2Server` at default settings (preface 30 s, keepalive 30 s), one TCP
client that sends nothing: both timers fire in one turn, the deadline destroys
the socket, the keepalive pings it, package:http2 orphans the PING completer
and fails it later in the root zone:

```
Unhandled exception:
HTTP/2 error: Connection error: Connection is being forcefully terminated. (errorCode: 10)
```

Separately, under TLS a socket that connected and sent nothing was held open
indefinitely (`tls_only.dart`: "STILL OPEN after 8s" with a 1 s deadline).

## Owner decision

None needed: a crash and an unbounded hold on defaults.
