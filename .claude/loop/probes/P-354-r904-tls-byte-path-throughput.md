---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r904_tls_pipe_speed/probe.dart
round: 904
commit: 66cabcb3
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/raw_socket_pipe.dart]
status: valid
promoted: no — a speed check for one change, not a regression bound; the gate holds no throughput floor
---

# P-354 — r904 tls byte path throughput

## Measures

Loopback TLS, 128 MiB in 64 KiB chunks, 5 runs, median MiB/s, both
directions. ARM=socket is `SecureSocket.connect` used as Stream + IOSink, the
direct secureConnect path before round 904; ARM=pipe is
`RawSecureSocket.secure` + `RawSocketPipe`, the proxy path and the direct path
after it.

## Control

The two arms against the same server, the same payload and the same run order;
only the client's byte path differs. The spread inside one arm (about 15 MiB/s)
is the noise floor any difference has to clear.
