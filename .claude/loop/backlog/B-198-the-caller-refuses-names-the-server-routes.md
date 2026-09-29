---
status: open
round: 525
commit: 6659c0ee
paths: [packages/core/rpc_dart/lib/src/core/metadata.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/b129_15_token_cap.dart
reason: "bench — CONFIRMED with a band in round 525: 129 to ~1018 characters of service name is routable by the policy and REFUSED by RpcMetadata.forClientRequest, so a responder can register and route a name this client cannot call. Split out of B-129, which files it as a hygiene item"
---

# B-198 — the caller refuses service names the server routes

**Split out of B-129 (item 15) by round 525**, which files it among eighteen "hygiene
items" whose witness is *"None — read and delete"*. It is a reachable interop failure.

## Measured (round 525)

`policy.maxMethodPathLength = 1024`; `forClientRequest` caps each token at 128.

```
   32 chars  routable       builds
  120 chars  routable       builds
  128 chars  routable       builds
  129 chars  routable       REFUSED by the caller     <- the band starts
  200 chars  routable       REFUSED by the caller
  600 chars  routable       REFUSED by the caller
 1020 chars  not routable   REFUSED by the caller     <- past the policy too

CONTROL 1206 chars  not routable   REFUSED by the caller
```

**129 to roughly 1018 characters is routable and uncallable.** The control confirms
the rows mean what they say: a name past the policy's OWN limit is both not routable
and refused, so the band is a disagreement rather than the two limits agreeing.

## Why it matters

A responder registers `myapp.v1.<long>.UserService`, the policy routes
`/myapp.v1.<long>.UserService/Get`, and `RpcMetadata.forClientRequest` throws an
`ArgumentError` before the request is built. The server is reachable by a foreign gRPC
client and not by this library's own caller.

Package-qualified protobuf names are the realistic case — deeply nested packages reach
128 characters without anything unusual.

## Fix sketch

Use the policy's `maxMethodPathLength` rather than a hardcoded 128.

**The obstacle, and why this is not a one-liner:** `forClientRequest` is a static
constructor with no policy in scope, which is presumably why the constant is there.
Either the limit has to be threaded in (changing a widely used static's signature), or
the per-token check has to be relaxed to a path-length check the policy can later
re-apply — the parse already enforces the real limit in `parseRpcMethodPath`, so the
token cap may be redundant rather than merely wrong.

Worth checking which of the two limits the 128 was meant to be: RFC-scale header
limits, a gRPC constraint, or an arbitrary guard.

## Owner decision

—
