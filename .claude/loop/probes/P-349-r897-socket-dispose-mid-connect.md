---
file: packages/transport/rpc_dart_socket/.dart_tool/probe/r897_dispose_mid_connect/probe.dart
round: 897
commit: 99126bfa
paths: [packages/transport/rpc_dart_socket/lib/src/rpc_socket_connect.dart]
status: stale (6967b453)
promoted: packages/transport/rpc_dart_socket/test/a_cancelled_connect_releases_its_socket_test.dart
---

# P-349 — r897 socket dispose mid-connect

## Measures

An `RpcClientConnection` whose factory is `connectRpcSocket` to
10.255.255.1:9, a SYN nobody answers; `dispose()` 500 ms in, while the
connection reads Connecting. `run.py` times the DISPOSED line to the process
exit (kills at 45 s). Arms: `hole` (default connectTimeout), `hole0`
(connectTimeout: null), `token` (`RpcClientConnection.cancellable` passing its
token, after the fix). Before: `hole` 19.6 s (twice), 7.6 s; `hole0` 14.8 s,
3.5 s -- this machine's OS gives the SYN up at a varying point. After: `token`
24-70 ms over four runs.

## Control

`refused`: 127.0.0.1:9, nothing listening: exit 38-50 ms after DISPOSED.
