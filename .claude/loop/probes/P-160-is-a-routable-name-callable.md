---
file: packages/core/rpc_dart/.dart_tool/probe/b129_15_token_cap.dart
round: 525
commit: 6659c0ee
paths: [packages/core/rpc_dart/lib/src/core/metadata.dart]
status: valid
---

# P-160 — is a routable service name callable?

## Why it exists

Two limits on one quantity disagree only in the range between them, so neither can be
read alone. The rig asks BOTH questions per row — would the policy route this path,
and will `forClientRequest` build it — and the disagreement is the rows where the
answers differ.

## The harness

A package-qualified protobuf name (`myapp.v1.<padding>`) at lengths chosen to straddle
both thresholds: well under 128, at 128, just past it, and up past the policy's 1024.
That shape matters — deeply nested packages reach 128 characters without anything
unusual, so the realistic case and the failing case are the same case.

## The numbers (round 525)

```
policy maxMethodPathLength = 1024

   32 chars  routable       builds
  120 chars  routable       builds
  128 chars  routable       builds
  129 chars  routable       REFUSED by the caller
  200 chars  routable       REFUSED by the caller
  600 chars  routable       REFUSED by the caller
 1020 chars  not routable   REFUSED by the caller

CONTROL 1206 chars  not routable   REFUSED by the caller
```

## Measures

Two booleans per name: routable by the policy, buildable by the caller. The
disagreement is the measurement — an absolute count of refusals would say nothing.

## Control

**A name past the policy's OWN limit, where both answers turn negative together.**
Without it, "routable / refused" rows are equally consistent with the two limits
agreeing and the rig mislabelling one column.

The short rows are the other half of the control: at 32 and 120 characters both answers
are positive, so the columns are not stuck.

## What it establishes, and what it does not

Establishes: 129 to roughly 1018 characters of service name is routable by the policy
and refused by `RpcMetadata.forClientRequest`. A responder can register and route a
name this library's own caller cannot construct a request for.

Does NOT establish that a real deployment hits it — no server was driven, and whether a
foreign gRPC client reaches such a method was not tested. The claim is about the two
limits, not about a field report.

Does NOT say which limit is correct. The 128 may be an RFC-scale header bound, a gRPC
constraint, or an arbitrary guard; nothing here distinguishes them, and a fix that
moves it without knowing is how a limit ends up wrong the other way.

## Reading

rpc_dart — **asks BOTH questions per row** — routable by the policy, buildable
by the caller — because a disagreement between two limits on one quantity is
invisible when either is read alone. The disagreement IS the measurement; a
count of refusals would say nothing. Its control is a name past the policy's
own limit, where both answers turn negative together, and the short rows are
the other half: at 32 characters both are positive, so neither column is
stuck.
