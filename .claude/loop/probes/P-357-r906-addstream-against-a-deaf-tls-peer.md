---
file: packages/core/rpc_dart/.dart_tool/probe/r906_deaf_addstream/probe.dart
round: 906
commit: 642329a8
paths: [packages/core/rpc_dart/lib/src/integration/secure_socket_connect.dart]
status: valid
promoted: packages/core/rpc_dart/test/integration/secure_socket_connect_test.dart
---

# P-357 — r906 addstream against a deaf tls peer

## Measures

A TLS server that completes the handshake and never reads; the client's
`addStream` of an endless 64 KiB-chunk source. Bytes pulled from the source
after 3 s, printed from inside the source so a starved timer cannot hide it.
`ARM=rpc` is `RpcSecureSocket`, `ARM=io` dart:io's `SecureSocket`.

## Control

`ARM=io`, dart:io's own socket against the same deaf peer: 832 KiB. The
adapter has to match it; a missing pause shows as the source running to its
256 MiB cap.
