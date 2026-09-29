---
file: packages/core/rpc_dart/.dart_tool/probe/b125_three_header_builders.dart
round: 517
commit: 739756f5
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/endpoint/ping.dart]
status: valid
---

# P-154 — do the three request-header builders agree?

## Why it exists

The lead's witness is a diff of three outputs for one context, including null. Two of
the three builders are private, so the diff has to be taken somewhere they are all
observable.

## The harness

Each call shape driven over a byte pipe — unary, server stream, ping — with the
header NAMES decoded from the metadata frame the caller actually sent, sorted so the
rows compare by eye.

**Read off the WIRE rather than by calling the builders.** Besides the privacy
problem, what a peer receives is the thing the lead's consequence is about; a builder
could agree and a caller still send something else.

The arms vary two things: the call shape, which selects the builder, and whether a
context was supplied — because the lead's specific claim is about the null case.

## The numbers (round 517)

```
WITH a context:
  unary  (UnaryCaller)           content-type, grpc-accept-encoding, grpc-timeout,
                                 x-request-id, x-route-service, x-trace-id
  server stream (CallProcessor)  content-type, grpc-accept-encoding, grpc-timeout,
                                 x-request-id, x-route-service, x-trace-id
  ping()                         content-type, grpc-accept-encoding,
                                 x-request-id, x-route-service, x-trace-id,
                                 x-rpc-ping-timestamp

With NO context (null):
  unary  (UnaryCaller)           content-type, grpc-accept-encoding,
                                 x-request-id, x-route-service, x-trace-id
  server stream (CallProcessor)  content-type, grpc-accept-encoding,
                                 x-request-id, x-route-service, x-trace-id
  ping()                         content-type, grpc-accept-encoding,
                                 x-request-id, x-route-service, x-trace-id,
                                 x-rpc-ping-timestamp
```

## Measures

Header names, sorted, per call shape. Not values: the claim is about which rules were
applied, and a name is present or it is not.

## Control

**The with-context rows are the control on the without-context rows.** `grpc-timeout`
appearing in the first set and not the second is what says the rig can see a
difference at all — three identical blocks with nothing varying would prove only that
the same frame was read three times.

That matters more than usual here, because of how the rig first failed.

## What it establishes, and what it does not

Establishes: the three builders produce the same header set for the same context,
including the null case the lead names. Unary carries `x-request-id` there. The two
differences that exist — `grpc-timeout` only with a deadline, `x-rpc-ping-timestamp`
only on ping — are both correct.

**Does NOT establish that the builders share code.** They do not; the lead's
structural point stands and only its stated consequence is refuted.

**A false start worth keeping.** The transport's connection window-update is itself a
metadata frame and precedes the request, so the first version reported
`x-rpc-conn-window-update` alone from all three arms — three identical rows, which is
exactly what the true answer also looks like. A negative that arrives that easily
needs a second look; the rig now skips frames carrying nothing but `x-rpc-`
bookkeeping.
