---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/cancel_before_the_trailer.dart
round: 385
commit: 8315658d
paths: [packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
status: valid
---

# P-78 — cancelling one beat before the trailer, on HTTP/2

## Why it exists

Round 385's endings matrix was clean on http2 on both links, and then the duplex
arms killed the connection over the latent one — after calls that had COMPLETED.
This isolates the variable: not the ending, not the concurrency, but **when the
consumer lets go**.

## Measures

Five mirror calls of 12 messages, and a unary ping after each: `pong`, `HUNG`,
or `DEAD`. The count of payloads received comes with it, so a dead connection is
distinguishable from a wrong answer.

Four arms, each differing from its neighbour by ONE thing:

- `direct, at last payload` — cancel when the 12th message arrives
- `direct, after done` — wait for onDone (the trailer), then cancel
- `50 ms, at last payload` — the same early cancel, over the relay
- `50 ms, after done` — the same late cancel, over the relay

The first three are the controls for the fourth's two variables: the link, and
the instant.

## The relay also answers "which side"

Its two pipes are labelled, so a hangup is attributed rather than guessed:
`client closed`, `server closed`, or a reset with its error. It needs
`unawaited(socket.done.catchError(...))` on both sockets — a write to a socket
the peer has reset surfaces on `done`, not from `add()`, and without it the
probe dies instead of the library. That cost one run.

## Control

The two `after done` arms are the sharp ones: same link, same calls, same
cancel, moved one event later. Both clean. And the direct/early arm shows the
early cancel is harmless when the trailer has already landed.

A `LogController` on the server is the second instrument, and it is what
established the cause is NOT in rpc_dart: the direct arm logs five handled
cancellations and survives; the latent arm logs nothing at warning or above and
dies.

## The numbers (round 385)

```
link     consumer lets go at   result
direct   the last payload      5 of 5 clean
direct   onDone (the trailer)  5 of 5 clean
50 ms    the last payload      DEAD from call 2   <- server closed
50 ms    onDone (the trailer)  5 of 5 clean
```

## What it establishes, and what it does not

Establishes: on HTTP/2 over a link with a round trip, a consumer that cancels
after the last payload and before the trailer costs the whole connection, and
the server is what closes it.

Does not establish the line inside `package:http2` that does it, nor whether a
conforming server would tolerate the reset (RFC 9113 says it should). Nor
anything about websocket or isolate, whose cancellation is a metadata frame
rather than a stream reset — both were measured clean in the same round.
