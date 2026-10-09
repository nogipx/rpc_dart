---
file: packages/core/rpc_dart/.dart_tool/probe/r768_pause_resume_window.dart
round: 768
commit: c58eb55b
paths: [packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-268 — what a message larger than the window does

## Measures

A server stream of N messages of SIZE characters over
`RpcChannelTransport.pair`, the caller pausing before the server sends and
resuming 300 ms later (`pause`) or reading throughout (`nopause`). Printed:
messages received and whether the stream finished within WAIT seconds.
`WINDOW=0` is the default policy (4 MiB stream window, 64 MiB connection,
16 MiB messages); any other value sets only the connection window.

## Control

SIZE within the window (8192, or 5 MB under the default policy): every
message arrives in both arms.
