---
file: packages/core/rpc_dart/.dart_tool/probe/b205_what_a_scope_costs.dart
round: 608
commit: 29ec4134
paths: [packages/core/rpc_dart/lib/src/logger/log_scope.dart]
status: valid (round 608)
---

# P-215 — what a per-call log scope costs

## Why it exists

B-205: is deriving `LogScope`s per call worth optimising?

## The harness

Times 200 000 rounds of the five derivations one unary call makes, and 3 000 unary
calls over `memoryPair` with a logger attached at `warning`; medians of five runs.

## The numbers (round 608)

```
five scopes          228 ns
one unary call     66801 ns
share               0.34 %
```

## Measures

Nanoseconds per call spent deriving scopes, as a share of the call.

## Control

The call itself.

## Reading

rpc_dart — the five `LogScope` derivations one unary call makes, timed against
the call itself: `228 ns` of `66801 ns`, 0.34 %; medians of five
