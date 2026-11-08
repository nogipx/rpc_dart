<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_acp

See the [public API reference](docs/api.md) and the
[stdio client example](example/README.md).

`rpc_acp` implements only the ACP client role. Applications use it to connect
to existing ACP agents. The package does not provide an API for implementing
an ACP agent; agent behavior belongs to the agent process.

`AcpClient` speaks ACP JSON-RPC through any `IAcpConnection`. It owns the ACP
version rules, session updates, and reverse requests from the agent. A local
agent can use `AcpJsonLineConnection` for its JSON-RPC stdio boundary.

For the unstable MCP-over-ACP transport, register `AcpMcpServer` instances in
the `AcpClient` constructor and pass their `toJson()` values as `mcpServers`
when creating, loading, or resuming a session. The agent must advertise
`mcpCapabilities.acp` in v1 or `session.mcp.acp` in v2. The registered handler
receives inner MCP methods and parameters and returns a carrier containing
exactly one `result` or `error`. Its notification callback sends a related
`mcp/message` notification while the request is active. The client rejects
unknown server IDs and ACP declarations the agent did not advertise support
for. This path has an in-memory protocol test; external-agent interoperability
has not been verified.

For a remote agent, wrap an `RpcPeerEndpoint` with `RpcAcpConnection` and pass
it to `AcpClient`. At the agent host, register `AcpTunnelReceiver` on another
`RpcPeerEndpoint` and give it the agent's `IAcpConnection`. Start each endpoint
after registering services. The tunnel carries complete decoded JSON-RPC
messages in both directions and does not interpret ACP methods.

The two process boundaries have different formats. `RpcStdioCallerTransport` and `RpcStdioServer` carry
rpc_dart binary frames between Dart processes. The hosted ACP agent's stdio
still carries newline-delimited JSON-RPC. `rpc_acp` depends only on rpc_dart
core, so the RPC peer may instead use a socket, WebSocket, or another transport.

Session logs, watch cursors, and usage accounting belong to an application
host, not to ACP.
