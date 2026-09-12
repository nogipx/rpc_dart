---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/send_into_a_dead_socket.dart
round: 358
commit: a0355bfc
paths: [packages/transport/rpc_dart_websocket/lib/**]
status: valid
---

# P-49 — does a websocket send throw when the socket is already gone

Drives `RpcWebSocketChannel.send` directly, once per way the socket can be dead,
and reports what the send did plus the two flags a guard might key on. Add an
arm by adding a `setUp` that kills the socket differently.

**Each arm PRINTS its sampled flags BEFORE the send**, because one arm throws
into the root zone and takes the process with it — a row that never prints is a
row that was never measured.

## Measures

Three, all on the library's side: `channel.isClosed` and the wrapped
`WebSocketChannel.closeCode` sampled before the send, and where the failure
went — returned, caught synchronously, delivered to a zone, or fatal.

## Control

Two arms with no window at all: a live socket, and our own `close()` first,
which is the documented silent no-op. Both must read `returned`, or the bench is
measuring something other than the race.

```
arm                                 isClosed   closeCode  send
live socket (control)               false      -          returned
our close() first (control)         true       -          returned
peer closed, same turn              false      -          returned
peer closed, +1 turn                false      -          returned
peer closed, +50ms (onDone in)      true       1005       returned
our raw socket, behind the channel  true       1006       returned
our raw socket, same turn, ZONED    false      -          returned, zone saw it
our raw socket, same turn           false      -          ROOT-ZONE CRASH
```

**Rebuilt once, and the first version is the lesson.** It drove a full endpoint
pair — server, contract, parked handler, peer hangup — and could not tell the
arms apart: `0 escaped` in both, because `onDone` always won the race. The
window IS the subject, so the bench has to address it directly instead of
hoping a realistic scenario lands inside it.

The `ZONED` arm is not an observation, it is a candidate fix under test: it
builds the `IOWebSocketChannel` inside `runZonedGuarded`. That it alone survives
is what identifies the construction zone as the thing that decides.
