---
round: 652
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the witness test is the measurement
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
severity: S2
---

# Round 652 — a zero-copy response of the wrong type

## Target

A previous reviewer's undecided item: the zero-copy response paths of the
caller, which cast `directPayload` to the expected type.

## Hypothesis

An undecodable zero-copy response fails the call the way an undecodable
serialized one does: INTERNAL (round 631).

## Before

```
responder answers RpcInt, caller expects RpcString, memoryPair (zero-copy)
unary          _TypeError: type 'RpcInt' is not a subtype of type 'RpcString'
server stream  the same _TypeError on the stream
```

## Control

The serialized path, INTERNAL since round 631.

## Mechanism

RPC-25: two copies of one duty. `_processDirectResponse` and the unary
caller's zero-copy branch passed the cast's error through raw; the serialized
siblings map it with `_undecodableResponse`. A caller catching
`RpcException`, or an interceptor reading a status, missed it.

## After

Both zero-copy sites map through `_undecodableResponse`: RpcStatusException
13 on both shapes.

## Canary

Both sites back to the raw error: both arms read `_TypeError`.

## Gate

Recorded in round 657.

## Not fixed

`runtimeType` still appears in a few error messages and diagnostics in core
(channel frame decode errors, primitive `fromJson`, `transportType` in
metrics, two internal logs in `base_processor`). Under obfuscation it names
nothing; hygiene rather than correctness, left for a separate pass.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 652]`.
Test `packages/core/rpc_dart/test/zero_copy/a_zero_copy_response_of_the_wrong_type_is_internal_test.dart`.
