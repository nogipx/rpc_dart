---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b104_reconnect_window.dart
round: 495
commit: 027ca636
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
status: valid
---

# P-133 — which part of reconnect() answers what

## Why it exists

`reconnect()` is several awaits long and `_disconnected` was set part-way
through. Round 359 measured the factory await and moved the flag to cover it;
nothing asked about the two teardown awaits AHEAD of that line. So the bench does
not ask "is there a window" — it asks which SEGMENT of one method a call lands in,
and makes the segments separately addressable.

## The harness

A fake `WebSocketChannel` whose sink close takes a configurable delay, so the
segment under test can be held open on demand. Three arms, each issuing one fresh
call 50 ms in and reporting BOTH the status and what `health()` said at that
moment:

- close delay 600 ms, instant factory — lands in `_inner.close()`.
- instant close, factory delayed 600 ms — lands in the factory await, which is
  round 359's fixed window and therefore the control.
- no reconnect at all.

**The fake's stream must stay OPEN.** A first version used
`const Stream<Object?>.empty()`, which ends immediately, so the transport's own
`onDone` treated the peer as dropped at construction and set `_disconnected` for
a reason unrelated to the window: every arm then read alike and the arms could not
be told apart. A controller that is never closed fixes it.

## The numbers (round 495)

```
                          before                                    after
inside the CLOSE await    health=closed    RpcClosedException,  9    degraded, 14
inside the FACTORY await  health=degraded  RpcNoConnection,    14    degraded, 14
no reconnect in flight    health=healthy   no throw                  healthy, no throw
```

## Measures

The status code a fresh call receives, and whether it is retryable. Plus
`health().level` read immediately before the call — which turned out to carry a
second finding rather than context: CLOSED is terminal, and a supervisor polling
it during a recovery was told the transport was gone for good.

## Control

The FACTORY arm, which reads 14 before and after: it is the same method, the same
fake and the same 50 ms, differing only in WHICH await is held open. So the 9 is
the segment's doing, not the rig's.

And the no-reconnect arm, which must stay `healthy / no throw` — a flag moved
earlier is only correct if it is still scoped to the attempt.

## What it establishes, and what it does not

Establishes: the first two awaits of `reconnect()` answered FAILED_PRECONDITION
and reported CLOSED, where the rest of the same method answered UNAVAILABLE and
reported degraded.

Does NOT measure the duration of the real window against a real peer. The 600 ms
is chosen; dart:io's actual wait for a close frame the peer never sends is
reported elsewhere as seconds (B-134), and nothing here confirms that number.

## Reading

rpc_dart_websocket — **makes the SEGMENTS of one method separately
addressable**: a fake channel whose close is slow holds the teardown await
open, a slow factory holds the next one, and each arm issues one call 50 ms
in. The already-fixed segment is the control. Reports `health()` alongside the
status, which is where its second finding came from. Trap: the fake's stream
must stay OPEN — `Stream.empty()` ends at once and the transport then treats
the peer as dropped at construction, making every arm read alike
