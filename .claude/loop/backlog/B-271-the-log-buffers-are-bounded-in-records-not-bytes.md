---
status: open
round: 764
commit: c75ded51
paths: [packages/core/rpc_dart_log/lib/src/mcp_buffer.dart, packages/core/rpc_dart_log/lib/src/log_output.dart]
probe: packages/core/rpc_dart_log/.dart_tool/probe/r764_records_not_bytes.dart
reason: owner — adding a byte budget changes the documented "last N records" contract of two public classes
rank: 4
---

# B-271 — the log buffers are bounded in records not bytes

`LogCollectorMcpBuffer` keeps the last `maxRecords` records (5000 in the
executable and in `LogCollectorMcpServer.run`), and nothing bounds what a
record weighs except the transport's 16 MiB message ceiling. Measured in
round 764 (P-265): 1000 records of 256 KiB hold +343 / +358 MiB, against
+10 MiB for 100 B records. So a full default buffer of 256 KiB records is
about 1.7 GiB, and the ceiling allows 5000 x 16 MiB.

The peers are the operator's own apps: the collector binds loopback by
default and the README limits `--bind-all` to trusted networks. So the
reachable case is an app that logs large payloads (response bodies, dumps)
for a long session, and the cost is the collector's memory, not the app's.

The sender has the same shape, not measured: `LogCollectorOutput.bufferSize`
(2000 records) holds what the collector has not acknowledged, in the APP's
process, while the collector is down.

Options: a byte budget beside the count on both (`maxBytes`, oldest evicted
first, size taken from the encoded record), or a README line that the bound
is in records and large payloads multiply it, or nothing.

## Owner decision

—
