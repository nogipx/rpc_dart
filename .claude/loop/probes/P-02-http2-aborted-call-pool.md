---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/aborted_upload_pool.dart
round: 207 — the validating round
commit: 1d5efdda
paths: [packages/transport/rpc_dart_http2/lib/**]
status: stale (1d5efdda) — all three http2 transports changed since; repeat the control before reusing
---

# P-02 — does an http2 connection survive a cancelled stalled call?

A real `RpcHttp2Server` and one `RpcHttp2CallerTransport`, with a raw TCP relay
between them counting client-to-server bytes. Four runs: a bidi upload into a
deaf handler and a paused server-stream download, each ended two ways.

Run it with `melos exec --scope=rpc_dart_http2 -- fvm dart run
.dart_tool/probe/aborted_upload_pool.dart`. To test a mitigation, change how the
stalled stream is ended, or ablate rpc_dart's throttle (`_fcOnDelivered`'s pause
and the `getMessagesForStream` onPause/onResume hop) — that ablation is what
identifies the enabling condition.

## Measures

Whether a subsequent unary `Ping` completes on the SAME connection within 6 s,
before the stall, during it, and after the stalled call ends. Plus bytes on the
wire from the relay, not from the sender — the rule this package's upload test
paid for.

## Control

The stalled call is ended by DRAINING it (the handler consumes / the consumer
resumes) instead of by cancelling. Everything else is identical, and the
"during stall" reading proves both arms reached the same held-pool state before
they diverge. At validation:

```
UPLOAD                                ping before  stalled  ping@stall  ping after
  control: handler drains it             pong      68 KiB     HUNG        pong
  case:    client cancels it             pong      68 KiB     HUNG        HUNG

DOWNLOAD                              ping before  taken    ping@stall  ping after
  control: consumer resumes               pong     324 msg    HUNG        pong
  case:    consumer cancels               pong     372 msg    HUNG        HUNG

ablation, rpc_dart's throttle removed:
  upload control  14286 KiB on the wire, ping@stall pong, after pong
  upload case     15291 KiB on the wire, ping@stall pong, after pong
```

68 KiB is the HTTP/2 default connection window (65535 + framing), which names
the control under test: `flowControlWindowBytes` defaults to 4 MiB and
`maxConcurrentHandlers` to none, so neither can produce that number.

After the round-208 fix the same four runs read:

```
  upload   control : ping@stall pong, after pong,  4174 KiB on the wire
  upload   case    : ping@stall pong, after pong,  4171 KiB on the wire
  download control : ping@stall pong, after pong
  download case    : ping@stall pong, after pong
```

Both arms recovering is the FIX, not a broken bench: the bench still
discriminates, because reinstating either pause puts the corresponding arm back
to HUNG (round 208's two canaries). The wire figure moving from 68 KiB to
4171 KiB is the second thing to check — it is `flowControlWindowBytes`, and if
it ever climbs toward the 15291 KiB of the round-207 ablation, the budget has
stopped being enforced.
