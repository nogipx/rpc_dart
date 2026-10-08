---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r718_closed_transport_leaves_socket.dart
round: 718
commit: e8341816
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/raw_socket_pipe.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-234 — does a closed http2 caller release its socket?

A forwarder sits between the caller and a real h2 server. It speaks CONNECT
or forwards straight away, and never forwards the caller's FIN, so the far
side never closes. The run makes one call, calls `transport.close()`, waits
3 s, and counts the caller's sockets to the forwarder with `lsof -n -P -p
<pid>`. Run with `melos exec --scope=rpc_dart_http2 -- fvm dart run
.dart_tool/probe/r718_closed_transport_leaves_socket.dart`.

## Measures

The number of the caller process's own sockets still connected to the
forwarder 3 s after `close()`.

## Control

A direct-path arm (a `dart:io` `Socket`), and an ablation of the pipe:
`close()` without its `shutdown(send)`, with `destroy()` a no-op.

```
  arm                 open   3 s after close()
  CONTROL direct        1          0
  proxy, plaintext      1          0
  proxy, ablated        1          1
```

Peer-side observations are blind here and were tried first. A half-close and
a close both put one FIN on the wire, and writing into it drew an RST even
against a bare `RawSocket.shutdown(send)` client. Count the process's own
socket table instead.
