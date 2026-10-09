---
file: packages/data/rpc_data/.dart_tool/probe/r771_error_status.dart
round: 771
commit: fa6399e6
paths: [packages/data/rpc_data/lib/src/rpc/data_responder.dart, packages/data/rpc_data/lib/src/rpc/data_error.dart, packages/data/rpc_data/lib/src/client/data_service_client.dart, packages/core/rpc_dart/lib/src/core/protocol.dart]
status: valid
---

# P-271 — what a remote data client catches

## Measures

A version conflict (update with a stale `expectedVersion`) through
`DataServiceClient`, on two setups: `codec` (`RpcChannelTransport.pair`,
like any real transport) and `inmemory` (`DataServiceFactory.inMemory`,
zero-copy). Printed: the exception type, its status, and its code or
details.

## Control

The server side throws `RpcDataError(status: aborted, code:
VERSION_CONFLICT)`; that is the value a client should see.
