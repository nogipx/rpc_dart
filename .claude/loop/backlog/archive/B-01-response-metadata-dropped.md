---
status: closed (round 223) — out of the loop, ordinary roadmap work
round: 223
commit: 5bf4d34e
paths: [packages/core/rpc_dart/lib/**]
probe: packages/core/rpc_dart/.dart_tool/probe/response_metadata_visibility.dart
reason: owner decided (round 223) — a missing feature, not a defect; leaves the loop and becomes ordinary roadmap work
---

# B-01 — Response metadata is dropped wholesale

rpc_dart throws away ALL response metadata between the transport and the
application. Measured against a raw peer over a channel pair — rpc_dart's own
responder cannot SEND arbitrary response metadata either, so an
rpc_dart-on-both-ends pair could not tell "dropped" from "never sent":

    peer sent, headers  : {x-ratelimit-remaining: 42, x-server-build: abc123}
    peer sent, trailers : {x-rows-scanned: 1000}
    the app receives    : RpcString "pong"   <- and nothing else
    the API for it      : none on RpcCallerEndpoint

The data is already there: it arrives in an ordinary metadata frame and is read
in `rpc/streams/unary/caller.dart` and in the three streaming callers, which
take only `grpc-status`, `grpc-message`, `grpc-encoding` and drop the rest.

Against a real gRPC server this is a compatibility hole, not a missing
convenience: rate-limit budgets, pagination cursors, `retry-after`, auth
challenges.

## Why a round did not do it

These are TWO features, and half of it helps almost nobody:

1. the caller can READ response metadata — valuable only against third-party
   servers;
2. the responder handler can SET it — without this, users with rpc_dart on both
   ends get nothing.

## Recommended shape, if the owner wants it

Additive, non-breaking, identical for all four call shapes: a collector passed
as a parameter rather than a callback — no ordering surprises, one parameter,
read after the call.

```dart
final meta = RpcResponseMetadata();
final r = await caller.unaryRequest(..., responseMetadata: meta);
meta.headers['x-ratelimit-remaining'];
meta.trailers['x-rows-scanned'];
```

The server half mirrors it on `RpcContext`: the handler writes, and the
responder pipeline merges into the initial headers and the trailer.

## Owner decision

**Out of the loop — do it as ordinary work.** (Asked and answered in round 223.)

The measurement stands and the shape above is the one to build, but this is a
**missing capability, not a defect**, and the config's severity bar from round
191 on is crash / hang / leak / data loss. Left in the backlog it would be
declined as a target every round from here to the cap, which is a worse outcome
than being scheduled honestly outside the loop.

Both halves together, or neither: read-only is useless to the rpc_dart-on-both-
ends majority, and set-only is useless against third-party servers. Either half
alone leaves a whole population with nothing.

Closed here so the loop stops re-reading it. The measurement, the probe path and
the recommended API shape all stay on this page — this is the reference for
whoever picks the feature up.
