---
status: open
round: 833
commit: 6b39a916
paths: [packages/core/rpc_dart_log/lib/src/log_console.dart, packages/core/rpc_dart_log/lib/src/log_output.dart, packages/core/rpc_dart_log/lib/src/log_server.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/r833_console_output.dart
reason: risk — outside the round scope (owner: rounds in rpc_dart and the transports only); a suspicion from round 833, not measured
rank: 7
---

# B-290 — the remote log collector prints what clients send

Round 833 found rpc_dart's `ConsoleOutput` printing a record's text raw, so a
CR/LF in it forged a line and an ESC sequence drove the terminal; fixed
there. `rpc_dart_log` is a collector whose whole input is records sent by
REMOTE clients over WebSocket, and it has its own console
(`log_console.dart`) and outputs. If those print a received message, error
or data raw, any client that can reach the collector writes lines of its
choosing into the operator's console or log file.

Not measured: whether `log_console.dart` escapes, and what the MCP buffer
(`mcp_buffer.dart`) hands an agent.

## Owner decision

—
