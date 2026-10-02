---
file: packages/core/rpc_dart/.dart_tool/probe/b116_parser_and_send_copies.dart
round: 614
commit: e080cd83
paths: [packages/core/rpc_dart/lib/src/core/parser.dart, packages/core/rpc_dart/lib/src/core/protocol.dart, packages/core/rpc_dart/lib/src/core/channel_frame.dart, packages/core/rpc_dart/lib/src/core/frame_headroom.dart]
status: valid (round 614)
---

# P-218 — the parser and send copies

## Why it exists

B-116 items 1 and 2: the copies the round-507 fix left, on the send path
(`RpcMessageFrame.encode`, then `RpcChannelFrame._encode`) and in
`RpcMessageParser` (`addBytes`, then the body `sublist`).

## The harness

Microseconds per operation, warmed, on one gRPC-framed message of each size:
`parse` is the parser alone; `parse+keep` adds a copy of the body, which is
what a receiver that retains the message pays; `send` is
`RpcMessageFrame.encode` then `RpcChannelFrame.encodeData`.

## The numbers (round 614)

```
                   parse    parse+keep    send
before    64 B      0.08       0.08        0.04
before  4096 B      0.34       0.55        0.49
before    16 KiB    1.03       1.95        1.67
before     1 MiB  206.75     389.33      391.94
after     64 B      0.07       0.07        0.04
after   4096 B      0.08       0.32        0.40
after     16 KiB    0.09       1.04        0.87
after      1 MiB    0.09     256.50      232.03
```

"before" is the same probe with both changes switched off in place. Run-to-run
noise at 1 MiB is about 30 %; the 64 B row is the one that has to stay flat.

## Measures

The cost of the remaining receive and send copies per message.

## Control

The 64 B row: neither change applies below 4096 bytes on send, and the parser's
in-place path costs nothing there.
