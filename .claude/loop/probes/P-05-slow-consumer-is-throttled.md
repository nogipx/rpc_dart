---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/slow_consumer_is_throttled.dart
round: 213 — the validating round
commit: d2b3726b
paths: [packages/transport/rpc_dart_http2/lib/**]
status: valid — and currently RED; it is B-15's acceptance test
---

# P-05 — is a slow consumer throttled, or failed?

A real `RpcHttp2Server`, a client-stream upload of 3000 x 4 KiB (12 MiB, 3x the
default window), and a handler in one of three modes: drains at full speed,
drains at one message per 2 ms, or consumes nothing.

Run it with `melos exec --scope=rpc_dart_http2 -- fvm dart run
.dart_tool/probe/slow_consumer_is_throttled.dart`. The knob that matters is the
handler's per-message delay: it sets the rate gap, and the whole question is
whether a gap is survivable.

## Measures

Whether the caller's call future completes or fails, how long it took, and how
many messages the handler consumed. Consumption is counted in the handler, which
is the only place that knows what the application actually received.

## Control

The `fast` handler: the same rig with the rate gap removed. It has to complete,
or the bench is measuring the upload rather than the throttle. At validation:

```
  fast : completed 'done',  15.4 s, consumed 3000 of 3000
  slow : FAILED RpcStatusException(8) "Request exceeds the un-consumed window
         (4197354 > 4194304 bytes)", 2.1 s, consumed 67 of 3000
  deaf : FAILED, same status, 1.8 s, consumed 0
```

`slow` is the row that matters and it is why this bench exists: a handler doing
nothing wrong, reading every message, is killed after 2.1 seconds. The refusal
is not a stalled-consumer guard — nothing throttles the producer since round
208, so the backlog grows at the rate GAP and any gap crosses the window given
enough upload.

**This bench is expected to be red until B-15 lands**, at which point `slow` must
read "completed, consumed 3000" and take roughly the time its own rate implies.
That is the witness B-15 records as the thing being bought.
