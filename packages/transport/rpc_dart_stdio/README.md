<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_dart_stdio

`RpcStdioCallerTransport` and `RpcStdioServer` connect two Dart processes over
rpc_dart frames on stdin/stdout. The child must reserve stdout for RPC bytes;
write diagnostics to stderr.

The caller can wrap a child returned by `Process.start`:

```dart
final process = await Process.start('my-rpc-server', []);
final transport = RpcStdioCallerTransport.fromProcess(process);
final endpoint = RpcPeerEndpoint(transport: transport)..start();
```

The child serves one connection:

```dart
final server = RpcStdioServer(
  mode: RpcPeerMode((endpoint) {
    endpoint.registerServiceContract(myPeerContract(endpoint));
  }),
);
await server.start();
```

Use `RpcResponderMode` or `RpcStdioServer.createWithContracts` when only the
caller starts RPC calls. The server owns its channel and endpoint. `stop` can
drain active calls; the same stdio stream cannot be started a second time.
`RpcStdioCallerTransport.fromProcess` closes the child's stdin when the
transport closes. The caller still owns the process and its stderr stream.

`RpcStdioChannel` is the lower-level `IRpcChannel` for already-open byte
streams. Its output sink remains caller-owned by default; pass
`closeOutput: true` for a sink that should close with the channel.

An ACP agent uses a separate JSON-RPC stdio boundary. `rpc_dart_stdio` carries
rpc_dart frames between the caller and an ACP host; `rpc_acp` relays decoded
JSON-RPC messages through that connection.
