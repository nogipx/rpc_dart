---
file: packages/core/rpc_dart_log/.dart_tool/probe/r764_records_not_bytes.dart
round: 764
commit: c75ded51
paths: [packages/core/rpc_dart_log/lib/src/mcp_buffer.dart, packages/core/rpc_dart_log/lib/src/log_server.dart]
status: valid
---

# P-265 — what the log buffer holds when records are large

## Measures

A real `LogCollectorOutput` sends 1000 info events to a `LogCollectorServer`
whose `onRecord` feeds a default `LogCollectorMcpBuffer` (maxRecords 5000).
Printed once the buffer holds all 1000: the process RSS growth. The sender
reuses one message string, so the growth is the collector's.

Arms (argv[0]): `big` sends 256 KiB messages, `small` 100 B.

## Control

The `small` arm: same count, same path, +10 MiB.
