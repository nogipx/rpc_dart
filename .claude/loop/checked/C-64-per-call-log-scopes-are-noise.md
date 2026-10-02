---
round: 608
commit: 29ec4134
paths: [packages/core/rpc_dart/lib/src/logger/log_scope.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
scope: the per-call LogScope derivation (child, withContext) on the call path, and whether its names churn the level cache
---

# C-64 — per-call log scopes are 0.34 % of a call

Five derivations, as one unary call makes them, cost **228 ns** against **66.8 µs**
for the call over `memoryPair`. The names are fixed per shape and per registered
method, so the level cache sees a bounded set.

## Control

The call itself, measured in the same process, is the denominator.

## What it licenses

Not caching or pooling scopes for speed. A change here moves a third of a percent.

## What it does not

A heavily logged run: this measured derivation with logging at `warning`, not the
cost of emitting records.

`../probes/P-215-what-a-scope-costs.md`, `../rounds/608-a-third-of-a-percent.md`.
