---
round: 898
verdict: FIXED
packages: [rpc_dart_socket]
lens: RPC-25
bench: P-350 — new
commit: yes
severity: S2 — "a status or error type a caller branches on"
release: changelog
---

# Round 898 — an oversized socket request keeps its status

## Target

B-307 (rank 10), in the socket package round 897 just changed: one full
conformance run read UNAVAILABLE (14) for I-7 "oversizeRequest is status 8:
socket | serverStream", never reproduced. I-7 is one failure, one status.

## Hypothesis

The frame channel answers an oversized frame with a RESOURCE_EXHAUSTED
trailer and then closes; on a socket the close can beat the trailer. Fails if
oversized requests read 8 every time, at any size and under load.

## Before

P-350, socket, limit 64 KiB:

```
request        calls  status 8  status 14
64 KiB + 1      200     200        0     (also under 8 busy CPU loops)
1 MiB           100      66       34
8 MiB           100      12       88     "Write failed: Broken pipe / Connection reset by peer"
```

The witness, over a Unix socket at 8 MiB: 5 of 5 read 14. The conformance
matrix sends limit + 1, which is why it was green but once.

## Mechanism

RPC-25. The server's frame channel writes the trailer and then calls
`closeForOversize`; `RpcSocketChannel` did not implement it, so the frame
channel fell back to `close()`, which cancels the read subscription and
destroys the socket. The client is still writing the rest of a message
megabytes long; unread bytes at destroy make the kernel reset the
connection, and the reset discards what the client had received but not
read -- the trailer. The client is left with its own failed write, which is
UNAVAILABLE, and `RpcRetryInterceptor` sends the same message again.
`RpcWebSocketChannel` implements `closeForOversize` and dart:io closes a
WebSocket with a handshake, so websocket never lost it.

## After

`RpcSocketChannel` implements `IRpcChannelOversizeClose`: it flushes the
queued writes with FIN as `close()` does, then reads and drops the peer's
remaining bytes until the peer closes, bounded by 32 MiB and by the close
timeout, and only then destroys the socket. `close()` is unchanged. P-350
after: 100 of 100 read 8 at 64 KiB + 1, 1 MiB and 8 MiB; 10 of 10 at 48 MiB.

## Canary

`an_oversized_request_reads_resource_exhausted_test.dart`, three ablations,
each restored after:

- `IRpcChannelOversizeClose` dropped from `implements`: WITNESS "a request
  far past the limit reads RESOURCE_EXHAUSTED" red, "Actual: ['status 14',
  'status 14', 'status 14', 'status 14', 'status 14']"; GUARDs green.
- the close timeout dropped from the drain: GUARD "a peer that trickles is
  cut off by the close timeout" red, "the drain followed the peer without a
  bound".
- the byte bound dropped: GUARD "a peer that sends fast is cut off by the
  byte bound" red, "the drain followed the peer past the bound this test
  leaves it". With a 300 ms close timeout this guard stayed green, since
  the timeout ended it too; it was given a 10 s one so only the byte bound
  can.

Restored: `+3`; the package `+41`.

## Gate

`test:unit:quiet --no-select`, `format:check`, `license:check`, `api:check`:
green. `analyze`: the first run red on an unneeded `dart:typed_data` import
in the new test; removed, then green.

## Siblings

- websocket: clean — P-350's websocket file, 40 of 40 at 64 KiB + 1, 1 MiB
  and 8 MiB.
- http: clean — P-350's http file, 40 of 40 at 8 MiB.
- http2: clean — P-350's http2 file, 40 of 40 at 8 MiB.
- isolate: n/a — no kernel socket, nothing to reset.
- wasm: n/a — in-process.
- channel: n/a — `RpcFrameMultiplexedChannel.pair` runs over in-memory
  streams, no kernel socket.
- caller: n/a — the refusing side is the responder; a caller that refuses an
  oversized response takes the same `closeForOversize` and drains the
  server's rest, which the server does not need.
- responder: fixed here.
- (not a group member) socket: fixed here.

## Not fixed

A request larger than the drain bound plus what the client reads in the
close timeout can still be reset; 48 MiB was not. The client cannot know the
server's limit before it sends.

## Links

B-307, I-7, RPC-25, P-350.
