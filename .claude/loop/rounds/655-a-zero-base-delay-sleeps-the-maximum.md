---
round: 655
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none — the witness test is the measurement; reviewer probe res2_backoff_bounds.dart
budget: probes 1/5, canaries 0/5
commit: yes
release: changelog
---

# Round 655 — a zero base delay sleeps the maximum

## Target

The resilience review: `ExponentialBackoff.delayFor`, used by the retry
interceptor and `RpcClientConnection`.

## Hypothesis

The delay is `baseDelay * 2^attempt`, capped, as the doc says.

## Before

```
no jitter, max 30 s
base 1 ms     a0=1ms   a1=2ms   a5=32ms
base 500 us   a0=30000ms a1=30000ms ...
base 0        a0=30000ms a1=30000ms ...
jitter, max 50 days   THROWS RangeError (49 days works)
```

## Control

The 1 ms row.

## Mechanism

RPC-23: the doc's formula against the code. Whole milliseconds truncated a
sub-millisecond base to 0, and `ms <= 0` -- the overflow guard -- turned 0
into `maxDelay`. `baseDelay: Duration.zero`, which reads as "no delay", slept
the maximum, 60 s by default, before every retry and reconnect. Jitter used
`Random.nextInt`, limited to 2^32.

## After

Microseconds; a zero base is zero; the cap is compared before multiplying,
with `~/` and `*` rather than shifts, which are 32-bit on the web; jitter by
`nextDouble`, still uniform in whole milliseconds [1, cap] as before (an
existing test pins it), in microseconds only for a cap under one. 500 us -> 0.5, 1, 16 ms; zero -> 0; 50 days with jitter stays in
(0, cap]; the 1 ms row unchanged.

## Canary

None run separately: the before rows are the reviewer's probe against the
unfixed code, the same arms as the witness.

## Gate

Recorded in round 657.

## Not fixed

Nothing known.

## Links

Lens `../lenses/RPC-23-the-narrative-beside-the-code.md` — `applied: [..., 655]`.
Test `packages/core/rpc_dart/test/resilience/exponential_backoff_bounds_test.dart`.
