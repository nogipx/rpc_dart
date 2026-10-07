---
round: 697
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — `packages/core/rpc_dart/test/endpoint/request_metadata_edges_test.dart`, five new cases
commit: yes
release: changelog
---

# Round 697 — connection headers are refused on send

## Target

B-193's protocol item, decided by the owner: connection-specific headers in
user metadata go out on HTTP/2, where RFC 9113 §8.2.2 makes the request
malformed. Refuse them on send with INVALID_ARGUMENT, as round 679 refuses
edge whitespace.

## Hypothesis

Nothing on the send path looks at the name beyond the reserved set.

## Before

A probe over http2 against `RpcHttp2Server`, each header as user metadata,
the handler echoing what it received:

```
connection -> v   keep-alive -> v   transfer-encoding -> v
upgrade -> v      proxy-connection -> v
```

rpc_dart's own server accepts all five; a strict peer must not. The committed
test, before the fix: `Expected: 'status 3'  Actual: 'v'`, all five.

## Mechanism

As hypothesised.

## Fix

`RpcHeaders.connectionSpecific`, the five names, and `checkUserHeader(name,
value)`, which refuses one of them and an edge-whitespace value. It replaces
round 679's `checkValueEdges` (not yet released) at the same three copy sites,
so the refusal happens before anything is sent, on every transport.

## After

9 of 9 in the file, the five new cases included.

## Canary

Before is the canary: the same five cases red before the change.

## The verdict questions

1. Yes: Before on the same tree.
2. Yes: the five names RFC 9113 lists.
3. Yes: the caller's status.
4. Not zero-valued.
5. Yes, quoted.
6. One cause.
7. Yes; the owner chose refusing over stripping.
8. None.

## Gate

`analyze`, `format:check`, `test:unit`.

## Not fixed

B-193's cost items -- headers re-validated, rebuilt per call, walked more than
once -- are hygiene, done separately by the owner's decision. `te` twice is
not reachable from user metadata: `te` is reserved and stripped.

## Links

Lead `../backlog/B-193-http2-header-helpers.md` -- protocol item done.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` -- `applied: [..., 697]`.
