---
round: 654
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the witness test is the measurement; reviewer probe res2_rate_limiter_server_stream_metered.dart
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 654 — a metered stream opened for free

## Target

The resilience review: `RpcRateLimiter.interceptServerStream` with
`meterServerStreamMessages: true`.

## Hypothesis

Every shape is charged when it is opened, as the class doc says.

## Before

```
global limit 2 per hour, ten server-streams emitting nothing
meterServerStreamMessages: false   handlerRuns=2  refused=8
meterServerStreamMessages: true    handlerRuns=10 refused=0
```

## Control

The `false` row.

## Mechanism

RPC-25. The metered branch skipped `_check`, ran the handler, and charged
responses only, with no first message prepaid -- where client-stream and bidi
charge at establishment and prepay their first message.

## After

Charged at opening on both settings; metered streams prepay the first
response. Both rows read 2 / 8; limit 3 over five responses delivers three.

## Canary

The opening charge skipped when metering: `handlerRuns 10`, and four
responses for three tokens.

## Gate

Recorded in round 657.

## Not fixed

Nothing known.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 654]`.
Test `packages/core/rpc_dart/test/resilience/a_metered_server_stream_is_charged_when_opened_test.dart`.
