---
file: packages/core/rpc_dart/.dart_tool/probe/caller_records_per_hostile_answer.dart
round: 797
commit: a8c7e4e6
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
status: valid
---

# P-288 — caller records per hostile answer

## Measures

A unary caller over `RpcChannelTransport.fromChannel` with its own
`LogController` (min level warning); a hand-built server answers each of
100 calls with initial headers, one DATA frame of the arm's kind and
grpc-status 0. Counts the caller's records at warning or above and the set
of outcomes the application saw.

```
  arm            records   outcome
  complete       0         ok
  oversized      100       RpcStatusException(8)
  twoResponses   100       RpcStatusException(13) "More than one response ..."
  badCbor        200       RpcStatusException(13) "Response could not be decoded"
```

badCbor's 200 are two records per call: "Failed to process response" and
"Unary call /Svc/u failed".

## Control

`complete`: the same caller, server shape and 100 calls; 0 records.
