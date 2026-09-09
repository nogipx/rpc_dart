---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_websocket/lib/**]
scope: [websocket]
---

# C-10 — Ghost stream ids from a hostile SERVER

The mirror of every ghost-id test in this repository — those attacked servers.
50000 frames carrying ids the client never issued: `streamControllers: 0`,
healthy.

It holds because controllers are created only in `getMessagesForStream`, on
local initiative. Pinned by `ghost_stream_ids_from_peer_test.dart`; the canary
(`putIfAbsent` in `_onMessage`) yields 20000 peer-allocated controllers.

## Control

The `putIfAbsent` canary in `_onMessage`: 20000 controllers, so the probe is
able to see them.
