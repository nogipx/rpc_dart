---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r868_tiny_messages_phases.dart
round: 868
commit: b18da1bb
paths: [packages/transport/rpc_dart_http2/test/tiny_messages_are_weighed_test.dart]
status: valid
promoted: no — the test it times is unchanged
---

# P-334 — the phases of the tiny-messages witness

`fvm dart run <file> [n]` from `packages/transport/rpc_dart_http2`. The
setup of `tiny_messages_are_weighed_test` (two client streams of 50 000
two-byte messages behind parked handlers, a 4 MiB connection window),
timed: how long the queueing phase takes, and how long the wait after the
handlers are released takes (the test caps it at 20 s). With `n` > 1 it
runs `n` copies at once.

## Measures

Which phase of the test grows with machine load.

## Control

n = 1: queueing 6.2 s, post-release 103 ms, both calls status 8.
