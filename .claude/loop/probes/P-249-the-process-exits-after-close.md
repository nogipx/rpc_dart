---
file: packages/core/rpc_dart/.dart_tool/probe/r746_driver.dart
round: 746
commit: f1b119b1
paths: [packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: valid
---

# P-249 — does the process exit once everything is closed?

The driver runs each fixture arm as its own process with the SDK's `dart`
(not the `fvm` wrapper, so a kill reaches the VM). It reports the time from
the fixture's "main returns" line to exit, or HUNG after 60 s. Fixtures:
`.dart_tool/probe/r746_exit.dart` in `rpc_dart_http2` (plain, ping, leak) and
in `rpc_dart_websocket` (plain, ping, conn, drop, leak). The fixtures never
call `exit()`.

Run from `packages/core/rpc_dart`:
`fvm dart run .dart_tool/probe/r746_driver.dart "<packageDir>|.dart_tool/probe/r746_exit.dart|<arm>" ...`

## Measures

Exit latency after `main` returns, per arm.

## Control

The `leak` arm leaves the server running and must report HUNG.
