---
file: packages/core/rpc_dart/.dart_tool/probe/b218_what_a_window_becomes.dart
round: 619
commit: 3cd9c2d1
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid (round 619)
---

# P-221 — what a window becomes

## Why it exists

B-218 item 2: how much memory one `flowControlWindowBytes` of wire bytes becomes
behind a paused consumer, with a codec that expands on decode against one that
does not.

## The harness

A server-stream firehose over `RpcChannelTransport.pair`, 1 KiB of wire per
message, into a caller that pauses after the first message. The response type
decodes into a `payload`-byte buffer with one byte written per 4 KiB page, so
anything decoded is resident, and it counts its decodes. One arm per process
(`-Darm=`): `lean` (1 KiB decoded), `fat` (16 KiB decoded), `nowindow`. The
window is 4 MiB, so a full one is visible in RSS.

## The numbers (round 619)

```
arm       window    produced   decoded   received   decoded bytes   RSS
lean      4096 KiB    4036        2          1          2 KiB       +38 MiB
fat       4096 KiB    4036        2          1         32 KiB       +38 MiB
nowindow  off      1513257        2          1          2 KiB       +37 MiB
```

The window fills (4036 messages, ~4 MiB of wire) and two are decoded. The
expanding codec moves nothing. RSS is the VM's own baseline in every arm.

## Measures

How many standing messages are decoded, and so what an expanding codec costs a
paused consumer.

## Control

The `lean` arm against `fat`.
