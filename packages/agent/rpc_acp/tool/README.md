<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_acp development tools

| Directory | Purpose |
| --- | --- |
| `wire/` | Capture traffic and validate it against pinned ACP schemas. Run `melos run check:acp-methods` and `melos run check:acp-wire`. |
| `tck/` | Run the client against the ACP TCK's reference agents. Run `melos run check:acp-client`. |
| `web/` | Compile and execute JavaScript probes. Run `fvm dart run tool/web/web_smoke.dart` from this package. |
| `mcp/` | Minimal stdio MCP echo server for integration probes. |


The ACP programs use the public `AcpMemoryConnections` and `AcpJsonLineConnection` transports. Shell scripts orchestrate checks; Python files validate captured messages and write reports. See [../docs/protocol/README.md](../docs/protocol/README.md) for coverage and limits.
