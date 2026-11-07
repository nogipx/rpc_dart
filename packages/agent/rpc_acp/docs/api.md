<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_acp public API

Import `package:rpc_acp/rpc_acp.dart`. This package implements the ACP client
role. It connects applications to existing agents and does not implement agent
behavior. All names below are exported from this library.

## AcpClient

Construct `AcpClient(IAcpConnection connection, {onPermissionRequest,
handlers, capabilities})`. The client owns the connection after construction;
`dispose()` closes it and the client's update streams. Call `initialize()`
before session methods. `kAcpProtocolVersion` defaults to v1 (`1`); request
draft v2 explicitly with `initialize(protocolVersion: kAcpProtocolVersionV2)`.
The result is `InitializeResult`, including the negotiated version, agent
capabilities, identity, and advertised authentication methods. An incompatible
version raises `AcpUnsupportedProtocolVersion`.

| Operation | Public method | Result |
| --- | --- | --- |
| Create session | `newSession({cwd, additionalDirectories, mcpServers})` | Session ID |
| Create session with setup data | `newSessionResult({cwd, additionalDirectories, mcpServers})` | `NewSessionResult` |
| Replay history | `loadSession(sessionId, {required cwd, additionalDirectories, mcpServers})` | `Stream<SessionUpdate>` |
| Replay raw events | `loadSessionStream(sessionId, {required cwd, additionalDirectories, mcpServers})` | `Stream<SessionUpdateEvent>` |
| Resume without replay | `resumeSession(sessionId, {required cwd, additionalDirectories, mcpServers})` | `ResumeSessionResult` |
| List sessions | `listSessions({cursor, cwd})` | `ListSessionsResult` |
| Delete or close | `deleteSession(sessionId)`, `closeSession(sessionId)` | `Future<void>` |
| Authenticate or log out | `authenticate(methodId)`, `logout()` | `Future<void>`, `Future<bool>` |
| Set mode or config | `setMode(sessionId, modeId)`, `setConfigOption(sessionId, configId, value)` | `Future<void>`, updated option maps |
| Run a turn | `prompt(sessionId, blocks)` | Stop reason string |
| Run a turn with raw events | `promptStream(sessionId, blocks)` | `Stream<SessionUpdateEvent>` |
| Cancel work | `cancel(sessionId)`, `cancelToolCall(sessionId, toolCallId)`, `cancelTerminal(sessionId, terminalId)` | `Future<void>` |

`prompt` accepts `List<PromptBlock>`. Constructors cover `text`, `image`,
`audio`, `resourceLink`, `resource`, and `command`. `promptStream` accepts
JSON content-block maps and yields a terminal `SessionUpdateEvent` with the
stop reason. `cancel` sends a notification; prompt completion confirms when
the turn actually stopped. `setMode` is v1 only; tool-call and terminal
cancellation are v2 only. ACP v2 requires an absolute `cwd` for session setup.

`updates` emits parsed updates during `prompt`; `allUpdates` emits every raw
`session/update` with its session ID, including notifications outside a turn.
`notices` emits user-facing notices. `availableCommands` holds the latest
advertised command list, and `commandsChanged` emits replacements.

`SessionUpdate` is sealed and keeps the original message in `raw`.
`parseSessionUpdate(raw)` recognizes message chunks, tool calls, plans,
configuration, usage, notices, compaction, state, diffs, terminals, and other
known updates; `UnknownUpdate` preserves unrecognized variants. Supporting
types include `AvailableCommand`, `SessionInfo`, `AuthMethod`, `DiffChange`,
and `DiffContent`.

## Agent requests to the client

Pass `onPermissionRequest` to choose a `SelectOption` from the agent's
`PermissionRequest.options`, or return `PermissionCancelled`. The current
default selects the first offered option; real applications should always
install their own approval handler.

`AcpClientHandlers` supplies optional handlers for agent requests: text-file
read/write, terminal create/output/wait/release/kill, and elicitation
create/complete. Advertise only handlers the application actually supports
using `AcpClientCapabilities`. Its fields cover file reads/writes, terminal,
elicitation form/URL, notices, compaction, config options, and terminal
authentication. Capabilities not advertised by default are false.

The request and response types are exported from `models.dart`, including
`ReadTextFileRequest`, `TerminalOutputResponse`, and
`ElicitationResponseMsg`. The models keep version-specific or extensible
payloads as JSON maps where appropriate.

## Connections

`IAcpConnection` carries decoded JSON-RPC maps through `messages`, `send`,
and `close`. `AcpJsonLineConnection(input, writeLine)` implements ACP JSON-RPC
over UTF-8 newline-delimited streams. The caller owns its input stream and
output sink; closing the connection does not close the process or sink.
`AcpMemoryConnections.create()` returns connected `client` and `agent`
connections for embedding or testing.

The only public JSON-RPC error type is `JsonRpcException`; error codes include
`kAuthRequired` and `kUnsupportedProtocolVersion`. `AcpClient` handles
request correlation and agent-originated requests internally.

## rpc_dart tunnel

`RpcAcpConnection(RpcPeerEndpoint endpoint)` adapts an application-side
rpc_dart peer to `IAcpConnection`. On the agent host, register
`AcpTunnelReceiver(endpoint, agentConnection)` as a service contract before
starting that endpoint. The receiver owns and closes `agentConnection` when
the tunnel ends. The application owns and closes its `RpcPeerEndpoint`.

The generated `IAcpTunnel.exchange` contract carries `AcpRpcMessage`, a
complete decoded JSON-RPC map. The tunnel never interprets ACP methods. Its
public generated caller, responder, names, and codecs are contract plumbing;
normal applications use `RpcAcpConnection` and `AcpTunnelReceiver`.

The rpc_dart peer may use any suitable rpc_dart transport. For stdio between
two Dart processes, use the separate `rpc_dart_stdio` package. The ACP agent's
own stdio still speaks newline-delimited JSON-RPC.

## MCP declarations

`newSession`, `loadSession`, and `resumeSession` accept `mcpServers` as a list
of ACP MCP server configuration maps. The declarations go to the agent as
part of session setup. The agent is responsible for connecting to MCP and
calling tools; `rpc_acp` does not host MCP tools. For a runnable setup, see
the [stdio client example](../example/README.md).
