---
file: packages/core/rpc_dart/.dart_tool/probe/r906_wss_speed/probe.dart
round: 906
commit: 642329a8
paths: [packages/core/rpc_dart/lib/src/integration/secure_socket_connect.dart]
status: valid
promoted: no — a speed check for one change, not a regression bound; the gate holds no throughput floor
---

# P-358 — r906 wss throughput io against rpc

## Measures

A WebSocket echo server over TLS on loopback, dart:io `WebSocket.connect` with
a custom `HttpClient`. 32 messages of 4 MiB sent and echoed (MiB/s of
payload), or with `SMALL=1` 1000 sequential 100-byte round trips (us per
round trip). 5 runs, median, arms interleaved io, rpc, io, rpc.

## Control

`ARM=io` is the client before round 906 (dart:io's own TLS connect); `rpc` is
the same client with `RpcSecureSocket` as its connection factory. The two io
passes differ by about 20 MiB/s and 20 us, which is the noise any difference
has to clear.
