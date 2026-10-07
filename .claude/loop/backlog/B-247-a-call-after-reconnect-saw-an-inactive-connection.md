---
status: closed (round 671) — by owner decision, 2026-10-07
round: 671
commit: 444e1bac
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/test/stream_ids_survive_reconnect_test.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/reconnect_then_inactive.dart
reason: "bench — seen once in round 671's gate; the probe that mirrors it read 608 of 608 clean, quiet and under gate load"
---

# B-247 — the first call after reconnect() saw an inactive connection

## Seen

Round 671's gate, a change to `rpc_dart_http` that cannot reach http2:

```
stream_ids_survive_reconnect_test  WITNESS: a call after reconnect does not reuse a live id
  RpcStatusException(14): HTTP/2 connection to 127.0.0.1:52762 is no longer
  active (the peer closed it or sent GOAWAY); reconnect and retry
  at RpcHttp2CallerTransport.sendMetadata (rpc_http2_caller_transport.dart:917)
```

The call was opened 300 ms after `reconnect()` returned. Green alone and in the
next gate.

## Measured

`reconnect_then_inactive.dart`: the test's scenario, 16 at a time, printing the
transport's health on failure.

```
quiet            208 of 208 ok
beside the gate  400 of 400 ok
```

## Why it matters

If real, `reconnect()` returned a transport whose connection was already dead,
or a late event from the OLD connection marked the new one inactive -- the
second is the shape B-179 names for keepalive ("a late probe can mark a new
connection dead").

## What a round owes this

A reproduction. The probe prints `health()` details on the failure, which
separates "the new socket died" from "a flag says it did".

## Owner decision

2026-10-07: **close** -- seen once; its probe read 608 of 608 clean.
