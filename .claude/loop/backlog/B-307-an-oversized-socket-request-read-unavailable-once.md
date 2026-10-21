---
status: closed (round 898)
round: 898
commit: 947f074c
paths: [packages/test/rpc_dart_conformance/test/i7_one_failure_one_status_test.dart, packages/transport/rpc_dart_socket/lib/**, packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart]
probe: P-350
reason: closed — CONFIRMED in round 898 (P-350: 34% at 1 MiB, 88% at 8 MiB read UNAVAILABLE; the socket close reset the connection under the client's unfinished write and the reset discarded the trailer) and fixed there: RpcSocketChannel.closeForOversize drains the rest, bounded
rank: 10
---

# B-307 — an oversized socket request read UNAVAILABLE once

One full conformance run failed I-7 "oversizeRequest is status 8: socket |
serverStream": the caller got 14 (UNAVAILABLE) where the matrix expects 8
(RESOURCE_EXHAUSTED). The file passed three times alone and the next full run
was green. The change under test was http2-only.

The frame channel answers an oversized frame with a RESOURCE_EXHAUSTED trailer
and then closes the channel (`_failChannel` -> `closeForOversize`). If the
close reaches the caller before the trailer, the caller sees a dead
connection, which is UNAVAILABLE: the status would depend on which of the two
lands first.

## Next step

Reproduce: the I-7 socket serverStream row in a loop, under load (other suites
beside it), counting 8 against 14. If 14 shows up, check whether the trailer
is written before the socket's close starts, and whether `RpcSocketChannel`'s
close flushes what is queued (it awaits `_writing` before `close()`).

## Owner decision

—
