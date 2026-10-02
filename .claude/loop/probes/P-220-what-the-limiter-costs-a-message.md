---
file: packages/core/rpc_dart/.dart_tool/probe/b213_what_the_limiter_costs_per_message.dart
round: 618
commit: 3cd9c2d1
paths: [packages/core/rpc_dart/lib/src/resilience/rate_limiter.dart]
status: valid (round 618)
---

# P-220 — what the limiter costs a message

## Why it exists

B-213: `RpcRateLimiter` re-resolves its counters on every message of a metered
stream. What does that cost against the message it meters?

## The harness

Two files. `b213_what_the_limiter_costs_per_message.dart` drives 200 000
integers through `interceptClientStream`'s metered stream with a limit nothing
reaches, so the limiter alone is timed. `b213_limiter_share_of_a_streamed_message.dart`
sends 20 000 messages over one client-stream call on a `memoryPair`, with the
limiter as a responder interceptor and without it; 11 runs each.

## The numbers (round 618)

```
limiter alone, ns per message (5 runs)
  no limiter              53-118
  static perMethod        242-294
  dynamic (keyExtractor)  367-392
  dynamic + global        430-525

one client-stream call, ns per message (11 runs)
  no limiter        min 3476  median 4366  max 13510
  dynamic + global  min 4319  median 4733  max 7451
```

## Measures

The per-message cost of metering, and of the re-resolution in particular
(dynamic minus static, about 120 ns).

## Control

The no-limiter arm of each file.
