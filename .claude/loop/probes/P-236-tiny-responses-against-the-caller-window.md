---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r720_tiny_responses_to_a_paused_caller.dart
round: 720
commit: 9097035e
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart]
status: valid
---

# P-236 — how many tiny responses a paused h2 caller accepts

A server-stream sends `count` responses of `''` (or 1 KiB) to a caller that
takes three and pauses. The server-side generator's count is read once it
stops. Run with `melos exec --scope=rpc_dart_http2 -- fvm dart run
.dart_tool/probe/r720_tiny_responses_to_a_paused_caller.dart paused 2000000`
(arms: `paused` | `reads` | `sized`).

## Measures

Responses the server produced before the caller's window stopped it.

## Control

The `sized` arm (1 KiB responses: the byte window binds) and the per-message
charge removed:

```
  arm                         produced
  sized, paused                   4245
  empty, payload-only charge    472002
  empty, weighed (r720)          36002
```

Round 729 added the `slow` arm (a reader pausing 1 ms every 20). With round
720's weighing it stopped at 34002 of 300000, and with payload alone the
server produced all 300000. Round 720 was retracted on that reading.
