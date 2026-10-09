---
file: packages/data/rpc_data/.dart_tool/probe/r767_stalled_watcher_ws.dart
round: 767
commit: 089d9446
paths: [packages/data/rpc_data/lib/src/repository/base_data_repository.dart, packages/data/rpc_data/lib/src/rpc/data_responder.dart, packages/data/rpc_data/lib/src/client/data_service_client.dart]
status: valid
---

# P-267 — what the data server holds for a paused watcher

## Measures

The server (`InMemoryDataRepository` + `DataServiceResponder` behind
`RpcWebSocketServer`) runs in this process; a child process watches
`notes`, and updates one record N times with a distinct 64 KiB payload.
Printed: the SERVER's RSS growth and what the child received.

Arms (argv[0]): `paused` (through `DataServiceClient`), `rawpaused` (the
generated `DataServiceContractCaller` on its own connection), `reading`.

**RSS cannot see it below the journal cap.** A buffered change is the same
object the journal keeps (5000 per collection by default), so holding it
costs nothing extra until the journal has evicted it. The count that
decided the round came from a temporary counter in `watch` (events added to
the `Stream.multi` listener while it was paused), removed afterwards.

`r767_stalled_watcher.dart` beside it is the one-process form, whose RSS
mixes both sides; `r767_status.dart` is round 767's side look at how data
errors cross the wire.

## Control

The `reading` arm: nothing added while paused. The `paused` arm is a second
control: `DataServiceClient` never pauses its inner subscription, so the
server never sees a pause and the client holds the backlog itself.
