---
file: packages/core/rpc_dart/.dart_tool/probe/r769_connection_total_slack.dart
round: 769
commit: 0e346aa6
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/stream_buffer_ledger.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart]
status: valid
---

# P-269 — what a paused caller meets at the connection total

## Measures

K server streams on one channel pair, each sending M messages of SIZE
characters. The streams open, the caller pauses all of them, then the
handlers start; with `RESUME` set the caller resumes after 2 s. Printed:
streams refused while paused, and in total. env K, M, SIZE, WINDOW
(connection window; 0 is the default policy), RESUME.

The refusal happens on RESUME, not during the pause: pausing first and
measuring only then reads clean (an earlier version of this probe, which
paused before the streams opened, saw nothing at all).

## Control

The same streams read throughout, or messages within the window: none
refused.
