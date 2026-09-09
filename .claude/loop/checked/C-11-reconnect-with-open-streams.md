---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_websocket/lib/**]
scope: [websocket]
---

# C-11 — reconnect() with open streams, and reuse of a live stream's id

- 5 reconnects with 4 live server streams each time: all 20 callers got a
  status, none hung, `activeStreams` returned to 0 every round, and a fresh call
  was served.
- The client half-closes right after sending the request, and
  `sendMetadata(endStream: true)` runs `_markFinished -> _releaseStream`,
  returning the id to the manager WHILE the response is still in flight. The
  manager does not hand it out again: 40 such calls got 40 distinct ids.
- `activeStreams` reads as 0 with 40 live calls, and that is not a defect but a
  metric of where we can still SEND. What bounds things are the per-stream
  controllers and the flow-control maps, which are different things.

## Control

40 half-closes in a row: 40 distinct ids, so there is no reuse.
