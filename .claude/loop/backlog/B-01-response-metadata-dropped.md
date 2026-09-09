---
status: awaiting owner
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/core/rpc_dart/lib/**]
probe: packages/core/rpc_dart/.dart_tool/probe/response_metadata_visibility.dart
reason: "two features at once: reading response metadata and setting it on the responder; half of it helps almost nobody"
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

—
