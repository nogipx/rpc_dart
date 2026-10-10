---
file: packages/core/rpc_dart/.dart_tool/probe/r825_refused_decode_credit.dart
round: 825
commit: dd400a08
paths: [packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor_caller.dart]
status: valid
promoted: — (a CLEAN measurement)
---

# P-306 — credit after decode refusals

## Measures

`RpcChannelTransport.pair` with the client's policy at `maxDecodedItems:
100`, a 128 KiB stream window and a 256 KiB connection window. `refusals`
server streams of ten 60 KB messages of 150 items each, which the client
refuses at decode (RESOURCE_EXHAUSTED on the first, the rest reaching a
torn-down stream); then an honest stream of twenty 60 KB messages of 50
items must arrive within 5 s.

```
  refusals   refused   honest stream (1.2 MB through a 256 KiB window)
  0          0         20 of 20, 63 ms
  2          2         20 of 20, 15 ms
  10         10        20 of 20, 10 ms
  30         30        20 of 20, 9 ms     (30 x 10 x 60 KB offered)
```

## Control

`RpcFlowController.onConsumed` made to credit nothing: the honest stream at
0 refusals ends `RpcDeadlineExceededException` after 5020 ms, so the window
binds on this pair and a leak of the size the refusals offer would stall it.
