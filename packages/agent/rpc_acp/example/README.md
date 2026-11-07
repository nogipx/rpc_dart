<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# ACP client example

Run one prompt against an installed ACP agent:

```sh
fvm dart run example/stdio_client.dart "Explain this project" -- agent-command agent-arg
```

The command after `--` must start an ACP agent that speaks JSON-RPC over
stdin/stdout. Replace `agent-command agent-arg` with that agent's actual launch
command. Agent diagnostics go to stderr. The example rejects permission
requests; applications should provide a user approval flow.

To make business tools available to the agent, supply MCP server declarations
in `ACP_MCP_SERVERS` before launching the example. For ACP v1, a stdio entry
has this shape:

```json
[
  {
    "name": "business-tools",
    "command": "/absolute/path/to/mcp-server",
    "args": [],
    "env": []
  }
]
```

The ACP client passes these declarations in `session/new`. The agent starts or
connects to the MCP server and decides when to use its tools. `rpc_acp` does not
execute MCP calls. The agent must support the chosen MCP server transport.

## Interactive REPL

`interactive_client.dart` keeps a session open and reads prompts from stdin.
Type a plain prompt, `/command` for a slash command, or `exit` to leave.

```sh
fvm dart run example/interactive_client.dart -- agent-command agent-arg
```

The REPL prints agent messages to stdout, notices and diagnostics to stderr,
and asks before granting any permission request. A real application should
replace the stdin prompt with its own approval UI.

## Tunnel to a remote agent

For an agent on another host, keep the same `AcpClient` calls and supply
`RpcAcpConnection` instead of `AcpJsonLineConnection`; register
`AcpTunnelReceiver` on the rpc_dart peer beside the agent. See the
[API reference](../docs/api.md#rpc_dart-tunnel).
