---
refines: U-07
paths: [packages/core/rpc_dart/lib/**]
applies: RpcSecurityPolicy has fields capping concurrency
breaks: "one way a dead limit, the other way a DoS: an unbounded rise in handlers, or denial of service."
applied: []
status: confirmed (round 114, off-journal)
---

# RPC-05 — Where a concurrency limit is charged

## Shape

A new limit charges the resource at the wrong point of the lifecycle.

## Detector

For every `RpcSecurityPolicy` field, where exactly it is checked: stream
admission, handler entry, dispatch.

## Ask

Charging at entry — is it a no-op against a burst? Charging at admission — does
it deny service to half-open streams?

## Evidence

30 calls past a ceiling of 3 when charged at entry; 8 metadata-only frames
refused every call for 60 s when charged at admission. Only dispatch works.
