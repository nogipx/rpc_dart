---
file: packages/core/rpc_dart/.dart_tool/probe/b111_rate_limiter_admission.dart
round: 502
commit: 33551cce
paths: [packages/core/rpc_dart/lib/src/resilience/rate_limiter.dart]
status: valid
---

# P-140 — what does RpcRateLimiter actually admit?

## Why it exists

A rate limiter is only interesting at the point of ADMISSION, and admission is
per call shape. `RpcRateLimiter` has four intercept methods and they charge
differently by design, so the question "is the limit enforced" has four answers
and no single call can find the one that is missing.

The rig therefore holds the limit fixed and varies the call SHAPE. Every arm opens
100 calls against `global: max 5`, so each printed number is directly comparable
with every other: `5` is enforcement, `100` is a bypass, and nothing has to be
reasoned about.

## The harness

The interceptor is driven directly with an `RpcMiddlewareContext`, no endpoint
round-trip — the idiom `rate_limiter_per_message_test.dart` already uses. A frozen
clock (`() => 0`) and a one-hour window mean the sliding window never advances, so
the count is the count.

Two details the arms depend on. The metering wraps the REQUEST stream, so it only
runs when the handler listens — every streaming arm drains its requests, or the
charge never happens and the arm measures nothing. And the refusal arrives as an
`RpcRateLimitException`, either thrown from the intercept call or pushed into the
returned stream, so each arm has to await the whole call to see it.

## The numbers (round 502)

Before:

```
CONTROL unary                      admitted 5 / 100  (must be 5)
CONTROL bidi, 1 request message    admitted 5 / 100  (must be 5)
bidi, ZERO request messages        admitted 100 / 100
client-stream, ZERO messages       admitted 100 / 100
unary, global 5 + perMethod 1000   admitted 100 / 100
```

After:

```
CONTROL unary                      admitted 5 / 100  (must be 5)
CONTROL bidi, 1 request message    admitted 5 / 100  (must be 5)
bidi, ZERO request messages        admitted 5 / 100
client-stream, ZERO messages       admitted 5 / 100
CONTROL 1 call, 10 messages, max 5 delivered 5  (must be 5, not 10)
unary, global 5 + perMethod 1000   admitted 100 / 100
```

The intermediate reading that changed the fix is worth keeping: charging
establishment ON TOP of per-message metering closed the hole (100 → 5) but moved
`CONTROL bidi, 1 request message` from 5 to 2, because such a call then cost two
tokens. The shipped fix prepays the first message against the establishment token,
which is why both controls read 5 in the after-table.

## Measures

Admitted calls out of 100, at one fixed limit, per call shape. Not latency, not
counter internals — the only thing a limiter is for is how many get through.

## Control

**Three, and they cover different failure modes of the rig.**

*Unary* must read 5: it is the shape known to charge one token per call, so a 100
there would mean the limiter is unconfigured or the harness swallows the
exception, and every other row would be uninterpretable.

*Bidi with one request message* must also read 5. This is what makes the empty-
stream arms a statement about ADMISSION rather than about bidi being unmetered
altogether — the same shape, one message different. It is also the arm that reads
collateral damage: it drops to 2 the moment the establishment charge stops being
prepaid.

*One call, ten messages, limit 5* must deliver 5 and not 10. "The open covers
message one" is one edit away from "the open covers every message", and without
this arm that edit reads as a pass everywhere else.

## What it establishes, and what it does not

Establishes: client-stream and bidi were metered per inbound request message and
nowhere else, so a call sending none was never charged — 100 of 100 admitted
against a limit of 5. After the fix they are admitted at establishment and read 5,
while every shape that does send messages costs exactly what it cost before.

Does NOT establish anything about the per-method/global resolution. The last arm
reads 100/100 both before and after, which is the documented contract
(`perMethod` > `perService` > `perKeyFallback` > `global`, "the first that
matches, and only that one") and not something this round changed. It is measured
here so the number exists when the owner decides on it.

Nor does it say anything about per-key counters, LRU eviction, or the cleanup
sweep — one `keyExtractor`-less limiter throughout.
