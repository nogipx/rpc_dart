---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b132_reset_status.dart
round: 528
commit: f53f3c46
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
status: valid
---

# P-162 — what status does a caller get for each way a WebSocket can end?

## Why it exists

A close code is the only thing a WebSocket peer can say about why it went away, and the
mapping from code to gRPC status decides whether a caller retries. Whether that mapping is
right cannot be read off the table: the question is which codes actually OCCUR for which
real failure, and one of them does not come from the peer at all.

So the rig drives the ENDINGS, not the codes — a reset, a vanished peer, an orderly
goodbye, a real server fault — and reads both the code the caller saw and the status its
in-flight call got.

## The harness

A WebSocket endpoint that answers NOTHING, so a call stays in flight until the arm tears
the connection down its own way.

The reset arm goes through a byte relay, because Dart has no SO_LINGER: the relay stops
draining the client and then destroys the socket, and **closing a socket with unread bytes
still in its receive queue is what makes the kernel send RST rather than FIN.** The arm
asserts the close code it produced, so a rig that silently degraded to FIN cannot read as a
pass.

The last arm uses a fake channel that RAISES instead of closing, which is the web shape:
`HtmlWebSocketChannel` reports a socket failure as an error on the stream where dart:io
reports a close.

**The process does not exit when the run finishes** — something on the torn-down arms keeps
the isolate alive — so the table prints and the run hangs. Do not pipe it through `tail`,
which waits for EOF and shows nothing at all.

## The numbers (round 528)

```
  how                            closeCode   the call got
  TCP RESET mid-call             1002        status 13 — WebSocket closed by peer with code 1002
  CONTROL peer vanishes (FIN)    1005        status 14 — The stream closed before the peer sent a status
  CONTROL peer closes 1001       1001        status 14 — The stream closed before the peer sent a status
  CONTROL peer closes 1011       1011        status 13 — WebSocket closed by peer with code 1011: server fault
  raw channel error (the web path)           raw WebSocketChannelException
```

After the fix, row 1 reads `status 14 — WebSocket connection failed with code 1002` and the
last row an `RpcStatusException` at 14; the two middle controls are unchanged.

## Measures

The close code the caller observes, and the status (or raw type) its call fails with. Both,
because the finding is that they disagree about who spoke.

## Control

**A code the peer really sent (1011) and a clean goodbye (1001, FIN).** Without them,
"reset gives INTERNAL" is equally consistent with the whole table being INTERNAL, and a fix
that moved 1002 could not be told from one that moved everything.

## What it establishes, and what it does not

Establishes: on dart:io a TCP reset reaches the caller as close code 1002, which the
mapping read as a peer protocol judgement — non-retryable INTERNAL — while the peer sent
nothing at all. And a raw channel error reached the caller as the channel package's own
exception type, with no gRPC status.

The mechanism is read from the SDK, not inferred: `websocket_impl.dart`'s socket `onError`
calls `_close(WebSocketStatus.protocolError)`, assigns that code to `_closeCode`, and closes
the controller WITHOUT adding an error — so it is indistinguishable from a protocol close.

Does NOT establish what a non-rpc_dart peer does. A peer that genuinely sends 1002 now gets
UNAVAILABLE too, and whether retrying that is better than failing is a judgement this rig
cannot make — it can only say that this library never sends 1002 itself, so between two
rpc_dart peers the local path is the only source.

Does NOT run on a browser. The web arm is the web SHAPE driven on the VM; no
`HtmlWebSocketChannel` was involved.
