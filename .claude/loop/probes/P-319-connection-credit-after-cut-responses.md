---
file: packages/core/rpc_dart/.dart_tool/probe/r852_credit_after_cut_responses.dart
round: 852
commit: 4209b1ba
paths: [packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport_inbound.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor_caller.dart]
status: stale (526c8d52)
promoted: no — a CLEAN measurement
---

# P-319 — connection credit after cut responses

`fvm dart run <file> <n> <cut|whole>` from the repo root. A caller
`RpcChannelTransport` over a fake channel, connection window 256 KiB, stream
window 128 KiB; `n` server streams, each one whole 1 KB message and a 60 KB
one (whole) or its first 59 KB (cut), then an OK trailer. It sums the
connection grants the caller sends (`x-rpc-conn-window-update`) against the
DATA bytes it received.

## Measures

Connection credit granted back by the caller, against the bytes it took in;
the difference is the initial window when nothing leaks.

## Control

`_creditConnection` made to send nothing:

```
arm                 received    granted     short
whole x10           600210 B    802333 B    -202123 B
cut x10             590100 B    793234 B    -203134 B
whole x10, ablated  600210 B    262144 B    +338066 B
```
